(** Consistency checks between [Codegen_builtins.builtin_c_mapping] and
    [Env_builtins.with_builtins].

    These two registries answer different questions — codegen's table maps
    [(module_path, name)] to emitted C symbol; env's registrations say
    which names typecheck can see (as builtin functions or trait methods).
    They must agree on at least the set of names, or we get silent drift:

    - If a name is in codegen but not in env: typecheck errors with
      "Undefined identifier" even though the call would work post-codegen.
      This is what the [is_genuine_type_error] filter used to paper over;
      removing it exposed asin/acos/cbrt as trait-method gaps.
    - If a name is in env but not in codegen: typecheck accepts the call,
      then codegen emits an unresolved symbol → C linker error.

    Scope: prelude-accessible entries ([module_path = ""]) only. Module-
    scoped entries ([module_path = "std/list"], etc.) are validated by the
    module loader against each module's own .brp signature file. *)

(** Names registered in codegen without an env counterpart.

    This list reflects the CURRENT state of drift. It's a visible TODO
    queue — the ideal is an empty list. Each group below has a disposition:

    - {b Should be registered in env as a trait method}: math functions that
      belong on [FloatingPoint] (mirroring [sin]/[cos]) but haven't been
      lifted yet.

    - {b Should be removed from codegen prelude}: module-scoped functions
      that shouldn't be prelude-accessible per [std/prelude.brp]. The
      [("", name)] codegen entries are unreachable after the
      [is_genuine_type_error] filter removal — typecheck rejects the call
      before codegen sees it. Cleanup is safe but mechanical.

    - {b Pending type-level design}: a few codegen-only helpers whose blorp
      signature is ambiguous (e.g. polymorphic on dim types).

    When fixing: register in env_builtins or remove from codegen_builtins,
    then remove from this list. *)
let codegen_only_prelude_names =
  [
    (* --- Float constant builtins — these are [private pure func] with
     [builtin] bodies in std/float.brp, backing the exported [INFINITY],
     [NEG_INFINITY], and [NAN] constant initializers. They're called
     unqualified during std/float.brp's top-level evaluation; the codegen
     prelude entry resolves the bare name. Not true drift — the private-
     function convention is how blorp currently implements module-scoped
     builtin primitives. --- *)
    "infinity";
    "nan_value";
    "neg_infinity";
  ]

let exception_set =
  lazy
    (let s = Hashtbl.create (List.length codegen_only_prelude_names) in
     List.iter (fun n -> Hashtbl.replace s n ()) codegen_only_prelude_names;
     s)

(** Is [name] visible to typecheck via [env]? *)
let is_env_visible (env : Blorp.Env.env) (name : string) : bool =
  Option.is_some (Blorp.Env.get_func_info env name)
  || Option.is_some (Blorp.Env.get_function_trait env name)

(** Every prelude-accessible codegen entry must either be env-visible or
    listed in [codegen_only_prelude_names]. New drift will surface here;
    clear the drift by registering in env_builtins (or removing from
    the prelude portion of codegen's builtin map) and deleting the exception. *)
let test_prelude_entries_registered () =
  let sess = Blorp.Session.create () in
  Blorp.Session.with_current sess (fun () ->
      let env = Blorp.Env_builtins.with_builtins (Blorp.Env.empty ()) in
      let exceptions = Lazy.force exception_set in
      let drift =
        List.filter_map
          (fun ((mod_path, name), _c_name) ->
            if mod_path <> "" then None
            else if is_env_visible env name then None
            else if Hashtbl.mem exceptions name then None
            else Some name)
          Blorp.Codegen_builtins.builtin_c_mapping
        |> List.sort_uniq String.compare
      in
      if drift <> [] then
        Alcotest.failf
          "New prelude-accessible codegen-builtin names missing from \
           env_builtins:\n\
          \  %s\n\n\
           Fix by either:\n\
          \  (a) Register in env_builtins.ml (add_func or add_trait_function)\n\
          \  (b) Remove the prelude entry from codegen_builtins.ml if the name \
           shouldn't be prelude\n\
          \  (c) Add to codegen_only_prelude_names in this file with a \
           category comment"
          (String.concat "\n  " drift))

(** Keep the exception list honest: every entry must still appear in
    codegen. A removed codegen entry whose exception lingers is a cleanup
    that should happen now, not a "might be needed someday". *)
let test_exception_list_not_stale () =
  let codegen_names =
    List.filter_map
      (fun ((mod_path, name), _) -> if mod_path = "" then Some name else None)
      Blorp.Codegen_builtins.builtin_c_mapping
    |> List.sort_uniq String.compare
  in
  let codegen_set = Hashtbl.create (List.length codegen_names) in
  List.iter (fun n -> Hashtbl.replace codegen_set n ()) codegen_names;
  let stale =
    List.filter
      (fun name -> not (Hashtbl.mem codegen_set name))
      codegen_only_prelude_names
    |> List.sort_uniq String.compare
  in
  if stale <> [] then
    Alcotest.failf
      "Stale entries in codegen_only_prelude_names — no longer in codegen:\n\
      \  %s\n\n\
       Remove these from the exception list."
      (String.concat "\n  " stale)

let test_list_ir_functions_not_shadowed_by_codegen_builtins () =
  let ir_functions =
    [
      "all";
      "any";
      "count";
      "drop_while";
      "filter";
      "filter_map";
      "find";
      "find_index";
      "flat_map";
      "fold";
      "fold_left";
      "fold_right";
      "for_each";
      "get_or";
      "map";
      "map_indexed";
      "max_by";
      "min_by";
      "partition";
      "scan";
      "set";
      "sort";
      "sort_by";
      "sort_desc_by";
      "take_while";
      "zip_with";
    ]
  in
  let shadowed =
    List.filter
      (fun name ->
        Option.is_some (Blorp.Codegen_builtins.lookup "std/list" name))
      ir_functions
  in
  if shadowed <> [] then
    Alcotest.failf
      "List functions with synthesized IR bodies should resolve through \
       std/list source functions, not Codegen_builtins:\n\
      \  %s"
      (String.concat "\n  " shadowed)

let test_builtin_lookup_uses_exact_module_paths () =
  Alcotest.(check (option string))
    "registered raylib alias resolves" (Some "blorp_raylib_init_window")
    (Blorp.Codegen_builtins.lookup "../games/raylib" "init_window");
  Alcotest.(check (option string))
    "arbitrary basename match does not resolve" None
    (Blorp.Codegen_builtins.lookup "/tmp/not-a-blorp-module/raylib"
       "init_window")

let test_builtin_effect_metadata_classifies_typechecker_sets () =
  let open Blorp.Builtin_metadata in
  List.iter
    (fun name ->
      Alcotest.(check bool) (name ^ " is impure") true (is_impure name))
    [ "print"; "read_file"; "write_file"; "getenv"; "send_timeout" ];
  List.iter
    (fun name ->
      Alcotest.(check bool) (name ^ " is not impure") false (is_impure name))
    [ "length"; "to_string"; "map" ];
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " is a parallel boundary")
        true
        (is_parallel_boundary name))
    [ "parallel"; "map_parallel"; "zip_parallel_with" ];
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " is not a parallel boundary")
        false
        (is_parallel_boundary name))
    [ "map"; "print"; "length" ]

let test_builtin_call_effect_metadata_distinguishes_waiting_modes () =
  let open Blorp.Builtin_metadata in
  let pp_wait fmt = function
    | No_wait -> Format.pp_print_string fmt "No_wait"
    | May_park_fiber -> Format.pp_print_string fmt "May_park_fiber"
    | May_block_thread -> Format.pp_print_string fmt "May_block_thread"
    | May_block_thread_and_park_fiber ->
        Format.pp_print_string fmt "May_block_thread_and_park_fiber"
  in
  let pp_cancel fmt = function
    | Not_cancellation_point ->
        Format.pp_print_string fmt "Not_cancellation_point"
    | Cancellation_point -> Format.pp_print_string fmt "Cancellation_point"
  in
  let pp_impure fmt { wait; cancellation } =
    Format.fprintf fmt "{ wait = %a; cancellation = %a }" pp_wait wait pp_cancel
      cancellation
  in
  let pp_call_effect fmt = function
    | Pure -> Format.pp_print_string fmt "Pure"
    | Impure impure -> Format.fprintf fmt "Impure %a" pp_impure impure
  in
  let call_effect_testable = Alcotest.testable pp_call_effect ( = ) in
  let impure_no_wait =
    Some (Impure { wait = No_wait; cancellation = Not_cancellation_point })
  in
  let impure_may_park =
    Some (Impure { wait = May_park_fiber; cancellation = Cancellation_point })
  in
  let impure_may_block =
    Some
      (Impure { wait = May_block_thread; cancellation = Not_cancellation_point })
  in
  let impure_may_block_and_park =
    Some
      (Impure
         {
           wait = May_block_thread_and_park_fiber;
           cancellation = Cancellation_point;
         })
  in
  Alcotest.(check (option call_effect_testable))
    "print is impure but does not park" impure_no_wait (call_effect "print");
  Alcotest.(check (option call_effect_testable))
    "sleep parks the current fiber" impure_may_park (call_effect "sleep");
  Alcotest.(check (option call_effect_testable))
    "recv can park the current fiber" impure_may_park (call_effect "recv");
  List.iter
    (fun name ->
      Alcotest.(check (option call_effect_testable))
        (name ^ " can park the current fiber")
        impure_may_park (call_effect name))
    [ "accept"; "read"; "write" ];
  Alcotest.(check (option call_effect_testable))
    "connect can block during DNS and park during socket connect"
    impure_may_block_and_park (call_effect "connect");
  Alcotest.(check (option call_effect_testable))
    "try_recv is impure but does not park" impure_no_wait
    (call_effect "try_recv");
  List.iter
    (fun name ->
      Alcotest.(check (option call_effect_testable))
        (name ^ " is impure but does not park")
        impure_no_wait (call_effect name))
    [ "close"; "set_reuse_addr"; "local_port" ];
  List.iter
    (fun name ->
      Alcotest.(check (option call_effect_testable))
        (name ^ " currently blocks an OS thread")
        impure_may_block (call_effect name))
    [ "listen"; "set_timeout" ];
  Alcotest.(check (option call_effect_testable))
    "parallel boundary is not a call effect" None (call_effect "parallel")

let test_builtin_call_effect_metadata_maps_runtime_symbols () =
  let open Blorp.Builtin_metadata in
  let expect_parking symbol =
    Alcotest.(check bool)
      (symbol ^ " may park") true
      (runtime_symbol_may_park_fiber symbol)
  in
  List.iter expect_parking
    [
      "blorp_sleep";
      "blorp_channel_send";
      "blorp_channel_recv";
      "blorp_channel_recv_int";
      "blorp_channel_recv_nullable";
      "blorp_channel_send_timeout";
      "blorp_channel_recv_timeout";
      "blorp_channel_recv_timeout_f32";
      "blorp_channel_recv_timeout_nullable";
      "blorp_tcp_accept";
      "blorp_tcp_connect";
      "blorp_tcp_read";
      "blorp_tcp_write";
    ];
  List.iter
    (fun symbol ->
      Alcotest.(check bool)
        (symbol ^ " does not park")
        false
        (runtime_symbol_may_park_fiber symbol))
    [ "blorp_channel_try_recv"; "blorp_tcp_listen"; "blorp_print" ]

let test_type_metadata_classifies_typechecker_policy () =
  let open Blorp in
  let open Ast in
  Alcotest.(check bool)
    "List is heap-indirected" true
    (Type_metadata.is_heap_indirected_name "List");
  Alcotest.(check bool)
    "record names are not heap-indirected by default" false
    (Type_metadata.is_heap_indirected_name "Point");
  Alcotest.(check (option string))
    "Int home" (Some "std/int")
    (Type_metadata.primitive_home (TyNamed ("Int", [])));
  Alcotest.(check (option string))
    "array home" (Some "std/tensor")
    (Type_metadata.primitive_home
       (TyArray (TyNamed ("Float", []), [ TyConstInt 3 ])));
  Alcotest.(check bool)
    "Int is a struct scalar field" true
    (Type_metadata.is_struct_scalar_field_type (TyNamed ("Int", [])));
  Alcotest.(check bool)
    "String is not a struct scalar field" false
    (Type_metadata.is_struct_scalar_field_type (TyNamed ("String", [])));
  Alcotest.(check bool)
    "String match space is open" true
    (Type_metadata.is_open_exhaustiveness_scalar_name "String");
  Alcotest.(check bool)
    "Bool match space is closed" false
    (Type_metadata.is_open_exhaustiveness_scalar_name "Bool")

let test_type_metadata_splits_operator_and_to_string_fallbacks () =
  let open Blorp in
  let open Ast in
  let list_int = TyNamed ("List", [ TyNamed ("Int", []) ]) in
  let tensor_int = TyArray (TyNamed ("Int", []), [ TyConstInt 4 ]) in
  Alcotest.(check bool)
    "Int has native operator fast path" true
    (Type_metadata.has_native_operator_fast_path_type (TyNamed ("Int", [])));
  Alcotest.(check bool)
    "Tensor has native operator fast path" true
    (Type_metadata.has_native_operator_fast_path_type tensor_int);
  Alcotest.(check bool)
    "List operators must dispatch through traits" false
    (Type_metadata.has_native_operator_fast_path_type list_int);
  Alcotest.(check bool)
    "List still has builtin to_string fallback" true
    (Type_metadata.has_builtin_to_string_fallback_type list_int);
  Alcotest.(check bool)
    "User record has no builtin to_string fallback" false
    (Type_metadata.has_builtin_to_string_fallback_type (TyNamed ("Widget", [])))

let test_builtin_metadata_classifies_special_inference () =
  let open Blorp.Builtin_metadata in
  let pp_special_inference fmt = function
    | Checked_get -> Format.pp_print_string fmt "Checked_get"
    | Checked_set -> Format.pp_print_string fmt "Checked_set"
    | Checked_slice -> Format.pp_print_string fmt "Checked_slice"
    | Matrix_checked_get -> Format.pp_print_string fmt "Matrix_checked_get"
    | Matrix_checked_set -> Format.pp_print_string fmt "Matrix_checked_set"
    | Tensor_checked_get n -> Format.fprintf fmt "Tensor_checked_get %d" n
    | Tensor_checked_set n -> Format.fprintf fmt "Tensor_checked_set %d" n
    | Assert_shape -> Format.pp_print_string fmt "Assert_shape"
    | Length_refined -> Format.pp_print_string fmt "Length_refined"
    | Type_name -> Format.pp_print_string fmt "Type_name"
    | Is_heap -> Format.pp_print_string fmt "Is_heap"
    | Vector_ctor -> Format.pp_print_string fmt "Vector_ctor"
    | Matrix_ctor -> Format.pp_print_string fmt "Matrix_ctor"
    | Tensor_ctor n -> Format.fprintf fmt "Tensor_ctor %d" n
    | Bitwise -> Format.pp_print_string fmt "Bitwise"
  in
  let special_inference_testable =
    Alcotest.testable pp_special_inference ( = )
  in
  Alcotest.(check (option special_inference_testable))
    "checked_get handler" (Some Checked_get)
    (special_inference "checked_get");
  Alcotest.(check (option special_inference_testable))
    "tensor4_checked_set handler" (Some (Tensor_checked_set 4))
    (special_inference "tensor4_checked_set");
  Alcotest.(check (option special_inference_testable))
    "length handler" (Some Length_refined)
    (special_inference "length");
  Alcotest.(check (option special_inference_testable))
    "bitwise handler" (Some Bitwise)
    (special_inference "shift_right");
  Alcotest.(check (option special_inference_testable))
    "ordinary std function has no special inference" None
    (special_inference "map")

let test_builtin_metadata_registry_integrity () =
  let open Blorp.Builtin_metadata in
  Alcotest.(check (list string))
    "descriptor names are unique" [] duplicate_names;
  Alcotest.(check (list string))
    "descriptors all carry behavior" [] inert_descriptor_names;
  Alcotest.(check bool)
    "unknown names are not registered" false
    (is_registered "__not_a_builtin__");
  Alcotest.(check bool)
    "registered special inference name is known" true
    (is_registered "checked_get")

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let read_first_existing paths =
  match List.find_opt Sys.file_exists paths with
  | Some path -> read_file path
  | None ->
      Alcotest.failf "Could not find any of:\n  %s" (String.concat "\n  " paths)

let startup_std_dir =
  let sess = Blorp.Session.create () in
  Blorp.Modules.init_module_paths ~sess (Sys.getcwd ());
  match Blorp.Modules.std_source_dir ~sess () with
  | Some dir -> dir
  | None ->
      Alcotest.failf
        "std source directory was not initialized from explicit config; CWD=%s"
        (Sys.getcwd ())

let read_std_file filename =
  let path = Filename.concat startup_std_dir filename in
  if Sys.file_exists path then read_file path
  else
    Alcotest.failf "Expected std source file at %s (std_source_dir=%s)" path
      startup_std_dir

let contains_substring haystack needle =
  let hay_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop i =
    i + needle_len <= hay_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let starts_with s prefix =
  let len = String.length s and prefix_len = String.length prefix in
  len >= prefix_len && String.sub s 0 prefix_len = prefix

let rec list_files_recursive dir =
  Sys.readdir dir |> Array.to_list
  |> List.concat_map (fun name ->
      let path = Filename.concat dir name in
      if Sys.is_directory path then list_files_recursive path else [ path ])

let relative_to_std path =
  let prefix = startup_std_dir ^ Filename.dir_sep in
  if starts_with path prefix then
    String.sub path (String.length prefix)
      (String.length path - String.length prefix)
  else path

let std_source_files_with_suffix suffix =
  list_files_recursive startup_std_dir
  |> List.filter (fun path -> Filename.check_suffix path suffix)
  |> List.map relative_to_std |> List.sort String.compare

let line_is_foreign_decl line =
  let line = String.trim line in
  line = "foreign:"
  || starts_with line "foreign("
  || starts_with line "foreign "
  || starts_with line "foreign\t"

let std_foreign_decl_modules () =
  std_source_files_with_suffix ".brp"
  |> List.filter (fun rel ->
      let source = read_std_file rel in
      source |> String.split_on_char '\n' |> List.exists line_is_foreign_decl)
  |> List.sort_uniq String.compare

let expected_std_foreign_decl_modules = []
let expected_std_native_header_files = []

let startup_pkg_dir =
  let dir = Filename.concat (Filename.dirname startup_std_dir) "pkg" in
  if Sys.file_exists dir && Sys.is_directory dir then dir
  else Alcotest.failf "Expected package source directory at %s" dir

let relative_to_pkg path =
  let prefix = startup_pkg_dir ^ Filename.dir_sep in
  if starts_with path prefix then
    String.sub path (String.length prefix)
      (String.length path - String.length prefix)
  else path

let pkg_source_files_with_suffix suffix =
  list_files_recursive startup_pkg_dir
  |> List.filter (fun path -> Filename.check_suffix path suffix)
  |> List.map relative_to_pkg |> List.sort String.compare

let pkg_foreign_decl_modules () =
  pkg_source_files_with_suffix ".brp"
  |> List.filter (fun rel ->
      let source = read_file (Filename.concat startup_pkg_dir rel) in
      source |> String.split_on_char '\n' |> List.exists line_is_foreign_decl)
  |> List.sort_uniq String.compare

let expected_pkg_foreign_decl_modules =
  [
    "compress.brp";
    "crypto.brp";
    "net/dns.brp";
    "net/tls.brp";
    "net/udp.brp";
    "sqlite.brp";
  ]

let expected_pkg_native_header_files =
  [
    "compress_ffi.h";
    "crypto_ffi.h";
    "net/tls_ffi.h";
    "net/udp_ffi.h";
    "sqlite_ffi.h";
  ]

let test_std_foreign_inventory_is_explicit () =
  Alcotest.(check (list string))
    "std modules with explicit foreign declarations"
    expected_std_foreign_decl_modules
    (std_foreign_decl_modules ())

let test_std_native_header_inventory_is_explicit () =
  let native_headers = std_source_files_with_suffix ".h" in
  Alcotest.(check (list string))
    "std native header files" expected_std_native_header_files native_headers

let test_pkg_foreign_inventory_is_explicit () =
  Alcotest.(check (list string))
    "pkg modules with explicit foreign declarations"
    expected_pkg_foreign_decl_modules
    (pkg_foreign_decl_modules ())

let test_pkg_native_header_inventory_is_explicit () =
  let native_headers = pkg_source_files_with_suffix ".h" in
  Alcotest.(check (list string))
    "pkg native header files" expected_pkg_native_header_files native_headers

let test_list_ir_hofs_have_no_runtime_c_abi () =
  let symbols =
    [
      "blorp_list_map";
      "blorp_list_filter";
      "blorp_list_filter_map";
      "blorp_list_fold_left";
      "blorp_list_fold_right";
      "blorp_list_for_each";
      "blorp_list_any";
      "blorp_list_all";
      "blorp_list_flat_map";
      "blorp_list_sort";
    ]
  in
  let runtime_decl =
    read_first_existing
      [
        "compiler/lib/runtime_decl.c";
        "../lib/runtime_decl.c";
        "lib/runtime_decl.c";
      ]
  in
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let stale =
    List.filter
      (fun symbol ->
        contains_substring runtime_decl (symbol ^ "(")
        || contains_substring runtime (symbol ^ "("))
      symbols
  in
  if stale <> [] then
    Alcotest.failf
      "Sequential List HOFs should be Core IR synthesized, not a C runtime ABI:\n\
      \  %s"
      (String.concat "\n  " stale)

let test_fiber_intrusive_links_are_role_specific () =
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let required =
    [
      ("run queue link", "struct blorp_Fiber* run_next;");
      ("channel wait link", "struct blorp_Fiber* wait_next;");
      ("object pool link", "struct blorp_Fiber* pool_next;");
      ("timer drain link", "struct blorp_Fiber* timer_drain_next;");
      ("run queue pop uses run_next", "queue->head = f->run_next;");
      ("channel enqueue uses wait_next", "(*tail)->wait_next = f");
      ("object pool uses pool_next", "__fiber_object_pool = f->pool_next;");
    ]
  in
  List.iter
    (fun (name, needle) ->
      Alcotest.(check bool) name true (contains_substring runtime needle))
    required;
  if contains_substring runtime "struct blorp_Fiber* next;" then
    Alcotest.fail
      "Fiber scheduler ownership must use role-specific intrusive links, not a \
       shared next pointer for run queues, channel waits, object-pool reuse, \
       and timer drain batches."

let test_std_source_dir_initialized_from_config () =
  Alcotest.(check bool) "std dir exists" true (Sys.is_directory startup_std_dir);
  Alcotest.(check bool)
    "std/list.brp exists" true
    (Sys.file_exists (Filename.concat startup_std_dir "list.brp"))

let test_list_join_uses_ir_string_append () =
  let list_src = read_std_file "list.brp" in
  if contains_substring list_src "builtin(\"blorp_string_append\")" then
    Alcotest.fail
      "List.join should use the synthesized IR string_append helper, not \
       direct blorp_string_append C runtime calls"

let test_builder_module_removed_from_std () =
  Alcotest.(check bool)
    "std/builder.brp removed" false
    (Sys.file_exists (Filename.concat startup_std_dir "builder.brp"))

let test_string_appends_have_no_legacy_runtime_c_abi () =
  let runtime_decl =
    read_first_existing
      [
        "compiler/lib/runtime_decl.c";
        "../lib/runtime_decl.c";
        "lib/runtime_decl.c";
      ]
  in
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let symbols =
    [
      "blorp_string_append_char";
      "blorp_builder_append_int";
      "blorp_builder_append_float";
    ]
  in
  let stale =
    List.filter
      (fun symbol ->
        contains_substring runtime_decl (symbol ^ "(")
        || contains_substring runtime (symbol ^ "("))
      symbols
  in
  if stale <> [] then
    Alcotest.failf
      "String appends should be source/Core IR, not a legacy C runtime ABI:\n\
      \  %s"
      (String.concat "\n  " stale)

let test_set_source_helpers_have_no_runtime_c_abi () =
  let runtime_decl =
    read_first_existing
      [
        "compiler/lib/runtime_decl.c";
        "../lib/runtime_decl.c";
        "lib/runtime_decl.c";
      ]
  in
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let symbols = [ "blorp_set_is_subset" ] in
  let stale =
    List.filter
      (fun symbol ->
        contains_substring runtime_decl (symbol ^ "(")
        || contains_substring runtime (symbol ^ "("))
      symbols
  in
  if stale <> [] then
    Alcotest.failf
      "Set source helpers should not be public C runtime ABI symbols:\n  %s"
      (String.concat "\n  " stale)

let test_wide_integer_boxes_are_arc_managed () =
  let runtime_decl =
    read_first_existing
      [
        "compiler/lib/runtime_decl.c";
        "../lib/runtime_decl.c";
        "lib/runtime_decl.c";
      ]
  in
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let required =
    [
      ( "runtime Int128 ARC allocation",
        runtime,
        "blorp_alloc(sizeof(blorp_Object) + sizeof(__int128))" );
      ( "runtime Int128 payload offset",
        runtime,
        "((char*)p + sizeof(blorp_Object))" );
      ( "runtime_decl Int128 ARC allocation",
        runtime_decl,
        "blorp_alloc(sizeof(blorp_Object) + sizeof(__int128))" );
      ( "runtime_decl Int128 payload offset",
        runtime_decl,
        "((char*)p + sizeof(blorp_Object))" );
      ( "runtime UInt128 ARC allocation",
        runtime,
        "blorp_alloc(sizeof(blorp_Object) + sizeof(unsigned __int128))" );
      ( "runtime_decl UInt128 ARC allocation",
        runtime_decl,
        "blorp_alloc(sizeof(blorp_Object) + sizeof(unsigned __int128))" );
    ]
  in
  List.iter
    (fun (name, src, needle) ->
      Alcotest.(check bool) name true (contains_substring src needle))
    required;
  List.iter
    (fun (name, src, needle) ->
      Alcotest.(check bool) name false (contains_substring src needle))
    [
      ("runtime Int128 raw malloc", runtime, "malloc(sizeof(__int128))");
      ( "runtime UInt128 raw malloc",
        runtime,
        "malloc(sizeof(unsigned __int128))" );
      ( "runtime_decl Int128 raw malloc",
        runtime_decl,
        "malloc(sizeof(__int128))" );
      ( "runtime_decl UInt128 raw malloc",
        runtime_decl,
        "malloc(sizeof(unsigned __int128))" );
    ]

let test_sized_integer_conversions_have_runtime_c_abi () =
  let runtime_decl =
    read_first_existing
      [
        "compiler/lib/runtime_decl.c";
        "../lib/runtime_decl.c";
        "lib/runtime_decl.c";
      ]
  in
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let conversions =
    [
      ("int8", "int8_t", "blorp_to_int8");
      ("int16", "int16_t", "blorp_to_int16");
      ("int32", "int32_t", "blorp_to_int32");
      ("int128", "__int128", "blorp_to_int128");
      ("uint8", "uint8_t", "blorp_to_uint8");
      ("uint16", "uint16_t", "blorp_to_uint16");
      ("uint32", "uint32_t", "blorp_to_uint32");
      ("uint64", "uint64_t", "blorp_to_uint64");
      ("uint128", "unsigned __int128", "blorp_to_uint128");
    ]
  in
  List.iter
    (fun (name, return_ty, symbol) ->
      let signature = return_ty ^ " " ^ symbol ^ "(long x)" in
      Alcotest.(check bool)
        ("runtime_decl " ^ name) true
        (contains_substring runtime_decl (signature ^ ";"));
      Alcotest.(check bool)
        ("runtime " ^ name) true
        (contains_substring runtime signature))
    conversions

type runtime_definition_check = Check_runtime_definition | Decl_only

type optimized_option_abi_case = {
  symbol : string;
  return_ty : Blorp.Ast.type_expr;
  params : string;
  runtime_return_override : string option;
  definition_check : runtime_definition_check;
}

let ty name = Blorp.Ast.TyNamed (name, [])
let option_ty payload = Blorp.Ast.TyNamed ("Option", [ payload ])

let tensor_ty elem dims =
  Blorp.Ast.TyArray (elem, List.map (fun n -> Blorp.Ast.TyConstInt n) dims)

let variadic_tensor_ty elem =
  Blorp.Ast.TyArray (elem, [ Blorp.Ast.TyVarDims "Ds" ])

let primitive_option_payloads =
  [
    (ty "Int", "int");
    (ty "Int8", "int8");
    (ty "Int16", "int16");
    (ty "Int32", "int32");
    (ty "Int64", "int64");
    (ty "UInt8", "uint8");
    (ty "UInt16", "uint16");
    (ty "UInt32", "uint32");
    (ty "UInt64", "uint64");
    (ty "Float", "float");
    (ty "Bool", "bool");
    (ty "Char", "char");
    (ty "Float32", "f32");
    (ty "Float16", "f16");
  ]

let primitive_option_family_cases prefix params =
  List.map
    (fun (payload_ty, suffix) ->
      {
        symbol = prefix ^ suffix;
        return_ty = option_ty payload_ty;
        params;
        runtime_return_override = None;
        definition_check = Decl_only;
      })
    primitive_option_payloads

let direct_optimized_option_abi_cases =
  [
    {
      symbol = "blorp_option_div_int";
      return_ty = option_ty (ty "Int");
      params = "long a, long b";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
    {
      symbol = "blorp_option_mod_int";
      return_ty = option_ty (ty "Int");
      params = "long a, long b";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
    {
      symbol = "blorp_assert_shape";
      return_ty = option_ty (variadic_tensor_ty (Blorp.Ast.TyVar "T"));
      params = "blorp_Vector* tensor, long expected_len";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
    {
      symbol = "blorp_string_get_opt";
      return_ty = option_ty (ty "Char");
      params = "const blorp_String* s, long index";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
    {
      symbol = "blorp_parse_int";
      return_ty = option_ty (ty "Int");
      params = "blorp_String* s";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
    {
      symbol = "blorp_parse_float";
      return_ty = option_ty (ty "Float");
      params = "blorp_String* s";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
    {
      symbol = "blorp_bytes_from_hex";
      return_ty = option_ty (ty "Bytes");
      params = "const blorp_String* s";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
    {
      symbol = "blorp_base64_decode";
      return_ty = option_ty (ty "String");
      params = "const blorp_String* s";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
    {
      symbol = "blorp_time_parse";
      return_ty = option_ty (ty "Int");
      params = "const blorp_String* s, const blorp_String* fmt";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
    {
      symbol = "blorp_time_from_iso";
      return_ty = option_ty (ty "Int");
      params = "const blorp_String* s";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
    {
      symbol = "blorp_getenv";
      return_ty = option_ty (ty "String");
      params = "const blorp_String* name";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
    {
      symbol = "blorp_read_line";
      return_ty = option_ty (ty "String");
      params = "void";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
    {
      symbol = "blorp_input";
      return_ty = option_ty (ty "String");
      params = "blorp_String* prompt";
      runtime_return_override = None;
      definition_check = Check_runtime_definition;
    };
  ]

let specialized_optimized_option_abi_cases =
  primitive_option_family_cases "blorp_vector_get_opt_"
    "blorp_Vector* arr, long index"
  @ primitive_option_family_cases "blorp_matrix_get_opt_"
      "blorp_Vector* arr, long row, long col"
  @ primitive_option_family_cases "blorp_dict_get_"
      "blorp_Dict* dict, void* key"
  @ primitive_option_family_cases "blorp_channel_recv_" "void* c"
  @ primitive_option_family_cases "blorp_channel_try_recv_" "void* c"
  @ primitive_option_family_cases "blorp_channel_recv_timeout_"
      "void* c, long timeout_ms"
  @ primitive_option_family_cases "blorp_stream_find_"
      "blorp_Stream* stream, blorp_Closure* pred"
  @ [
      {
        symbol = "blorp_vector_get_nullable";
        return_ty = option_ty (ty "String");
        params = "blorp_Vector* arr, long index";
        runtime_return_override = Some "void*";
        definition_check = Decl_only;
      };
      {
        symbol = "blorp_matrix_get_nullable";
        return_ty = option_ty (ty "String");
        params = "blorp_Vector* arr, long row, long col";
        runtime_return_override = Some "void*";
        definition_check = Decl_only;
      };
      {
        symbol = "blorp_vector_set_cow_nullable";
        return_ty = option_ty (tensor_ty (ty "String") [ 4 ]);
        params = "blorp_Vector* arr, long index, void* value";
        runtime_return_override = None;
        definition_check = Decl_only;
      };
      {
        symbol = "blorp_vector_set_cow_nullable_f32";
        return_ty = option_ty (tensor_ty (ty "Float32") [ 4 ]);
        params = "blorp_Vector* arr, long index, float value";
        runtime_return_override = None;
        definition_check = Decl_only;
      };
      {
        symbol = "blorp_dict_get_nullable";
        return_ty = option_ty (ty "String");
        params = "blorp_Dict* dict, void* key";
        runtime_return_override = Some "void*";
        definition_check = Decl_only;
      };
      {
        symbol = "blorp_channel_recv_nullable";
        return_ty = option_ty (ty "String");
        params = "void* c";
        runtime_return_override = Some "void*";
        definition_check = Decl_only;
      };
      {
        symbol = "blorp_channel_try_recv_nullable";
        return_ty = option_ty (ty "String");
        params = "void* c";
        runtime_return_override = Some "void*";
        definition_check = Decl_only;
      };
      {
        symbol = "blorp_channel_recv_timeout_nullable";
        return_ty = option_ty (ty "String");
        params = "void* c, long timeout_ms";
        runtime_return_override = Some "void*";
        definition_check = Decl_only;
      };
      {
        symbol = "blorp_stream_find_nullable";
        return_ty = option_ty (ty "String");
        params = "blorp_Stream* stream, blorp_Closure* pred";
        runtime_return_override = Some "void*";
        definition_check = Decl_only;
      };
    ]

let optimized_option_abi_cases =
  direct_optimized_option_abi_cases @ specialized_optimized_option_abi_cases

let optimized_option_policy_c_return reg meta ty =
  match Blorp.Core_option_layout.classify meta ty with
  | Known (StackScalar _ | StackValueRecord _) ->
      Blorp.Codegen_types.stack_option_c_type ~reg ty
  | Known NullableManagedPointer ->
      Option.map
        (Blorp.Codegen_types.type_to_c ~reg)
        (Blorp.Core_option_layout.nullable_managed_payload_type meta ty)
  | Known (BoxedUnion _) -> None
  | Unknown_named _ | Invalid_option_type _ -> None

let runtime_return_for_case reg meta case =
  let policy_return =
    match optimized_option_policy_c_return reg meta case.return_ty with
    | Some c_ty -> c_ty
    | None ->
        Alcotest.failf "%s does not use an optimized Option ABI" case.symbol
  in
  match case.runtime_return_override with
  | Some c_ty -> c_ty
  | None -> policy_return

let all_std_blorp_files () =
  let rec collect dir =
    Sys.readdir dir |> Array.to_list |> List.sort String.compare
    |> List.concat_map (fun name ->
        let path = Filename.concat dir name in
        if Sys.is_directory path then collect path
        else if Filename.check_suffix name ".brp" then [ path ]
        else [])
  in
  collect startup_std_dir

let std_impure_runtime_builtin_functions_without_call_effect () =
  let rec collect_decl path acc (decl : Blorp.Ast.decl) =
    match decl.decl_desc with
    | DPrivate inner -> collect_decl path acc inner
    | DFunc
        {
          func_name = Some func_name;
          func_is_pure = false;
          func_body = FuncBuiltinBody (BuiltinRuntime symbol, _);
          _;
        }
      when Option.is_none (Blorp.Builtin_metadata.call_effect func_name) ->
        Printf.sprintf "%s:%s -> %s" path func_name symbol :: acc
    | _ -> acc
  in
  all_std_blorp_files ()
  |> List.concat_map (fun path ->
      match Blorp.Modules.parse_source ~filename:path (read_file path) with
      | Error err -> Alcotest.fail err.message
      | Ok decls -> List.fold_left (collect_decl path) [] decls)
  |> List.sort String.compare

let std_module_path_for_file path =
  let rel = relative_to_std path in
  let without_ext =
    if Filename.check_suffix rel ".brp" then
      String.sub rel 0 (String.length rel - String.length ".brp")
    else rel
  in
  "std/" ^ without_ext

let codegen_runtime_symbol_for_std_builtin path func_name =
  let module_path = std_module_path_for_file path in
  match Blorp.Codegen_builtins.lookup module_path func_name with
  | Some _ as hit -> hit
  | None -> Blorp.Codegen_builtins.lookup "" func_name

let std_impure_builtin_runtime_symbols_without_call_effect () =
  let rec collect_decl path acc (decl : Blorp.Ast.decl) =
    match decl.decl_desc with
    | DPrivate inner -> collect_decl path acc inner
    | DFunc
        {
          func_name = Some func_name;
          func_is_pure = false;
          func_body = FuncBuiltinBody (builtin_kind, _);
          _;
        } -> (
        match Blorp.Builtin_metadata.call_effect func_name with
        | None -> acc
        | Some expected_effect -> (
            let runtime_symbol =
              match builtin_kind with
              | BuiltinRuntime symbol -> Some symbol
              | BuiltinIntrinsic ->
                  codegen_runtime_symbol_for_std_builtin path func_name
            in
            match runtime_symbol with
            | None -> acc
            | Some symbol
              when Blorp.Builtin_metadata.call_effect_for_runtime_symbol symbol
                   = Some expected_effect ->
                acc
            | Some symbol ->
                Printf.sprintf "%s:%s -> %s" path func_name symbol :: acc))
    | _ -> acc
  in
  all_std_blorp_files ()
  |> List.concat_map (fun path ->
      match Blorp.Modules.parse_source ~filename:path (read_file path) with
      | Error err -> Alcotest.fail err.message
      | Ok decls -> List.fold_left (collect_decl path) [] decls)
  |> List.sort String.compare

let test_std_impure_runtime_builtins_have_call_effect_metadata () =
  let missing = std_impure_runtime_builtin_functions_without_call_effect () in
  if missing <> [] then
    Alcotest.failf
      "Impure std builtin runtime functions need explicit call-effect metadata:\n\
      \  %s"
      (String.concat "\n  " missing)

let test_std_impure_runtime_symbols_have_call_effect_metadata () =
  let missing = std_impure_builtin_runtime_symbols_without_call_effect () in
  if missing <> [] then
    Alcotest.failf
      "Impure std builtin runtime symbols need explicit call-effect metadata:\n\
      \  %s"
      (String.concat "\n  " missing)

let std_declared_type_names () =
  let names = Hashtbl.create 64 in
  let rec add_decl decl =
    match (decl : Blorp.Ast.decl).decl_desc with
    | DType t -> Hashtbl.replace names t.type_name ()
    | DRecord r -> Hashtbl.replace names r.record_name ()
    | DTypeAlias a -> Hashtbl.replace names a.alias_name ()
    | DPrivate inner -> add_decl inner
    | _ -> ()
  in
  all_std_blorp_files ()
  |> List.iter (fun path ->
      match Blorp.Modules.parse_source ~filename:path (read_file path) with
      | Error err -> Alcotest.fail err.message
      | Ok decls -> List.iter add_decl decls);
  names

let test_public_abi_types_have_std_anchors () =
  (* LiteralString is intentionally omitted: it is a compile-time refinement
     of String, not a standalone runtime type. Module, Task, Tensor, Vector,
     Matrix, Builder, and Slice are internal/legacy ABI names; if any becomes
     source-facing, add a std declaration and include it here. *)
  let required =
    [
      "Bool";
      "Bytes";
      "Channel";
      "Char";
      "ConcurrencyError";
      "Dict";
      "Fixed";
      "Float";
      "Float16";
      "Float32";
      "Int";
      "Int8";
      "Int16";
      "Int32";
      "Int64";
      "Int128";
      "List";
      "MemStats";
      "SchedulerStats";
      "Option";
      "Ptr";
      "Result";
      "Set";
      "Stream";
      "String";
      "StringSlice";
      "TcpListener";
      "TcpStream";
      "UInt8";
      "UInt16";
      "UInt32";
      "UInt64";
      "UInt128";
      "Void";
    ]
  in
  let declared = std_declared_type_names () in
  let missing =
    List.filter (fun name -> not (Hashtbl.mem declared name)) required
  in
  if missing <> [] then
    Alcotest.failf "Public ABI types must have source anchors in std/:\n  %s"
      (String.concat "\n  " missing)

let test_tcp_handle_abi_types_are_managed_runtime_pointers () =
  let reg = Blorp.Codegen_types.create_registry () in
  let meta = Blorp.Core_type_layout.metadata_for_registry reg in
  let check_handle name expected_c =
    let ty = ty name in
    Alcotest.(check string)
      (name ^ " C ABI") expected_c
      (Blorp.Codegen_types.type_to_c ~reg ty);
    Alcotest.(check bool)
      (name ^ " requires release")
      true
      (Blorp.Core_type_layout.requires_release_or_error meta ty);
    Alcotest.(check bool)
      (name ^ " requires retain")
      true
      (Blorp.Core_type_layout.requires_retain_or_error meta ty)
  in
  check_handle "TcpListener" "blorp_TcpListener*";
  check_handle "TcpStream" "blorp_TcpStream*"

let test_tcp_runtime_handle_model_is_explicit () =
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let runtime_decl =
    read_first_existing
      [
        "compiler/lib/runtime_decl.c";
        "../lib/runtime_decl.c";
        "lib/runtime_decl.c";
      ]
  in
  let required_runtime =
    [
      "typedef struct blorp_TcpInner";
      "struct blorp_TcpListener {";
      "struct blorp_TcpStream {";
      "blorp_TcpInner* inner;";
      "static void blorp_tcp_listener_destructor(void* obj)";
      "static void blorp_tcp_stream_destructor(void* obj)";
      "static void blorp_tcp_inner_close(blorp_TcpInner* inner)";
      "BLORP_SET_DESTRUCTOR(listener, blorp_tcp_listener_destructor);";
      "BLORP_SET_DESTRUCTOR(stream, blorp_tcp_stream_destructor);";
      "static bool blorp_tcp_fd_arg_to_open_socket_fd(";
      "static bool blorp_tcp_fd_is_stream_socket(int raw_fd)";
      "static bool blorp_tcp_fd_is_listening_stream_socket(int raw_fd)";
      "static blorp_TcpListener* blorp_tcp_listener_from_open_fd(int raw_fd)";
      "static blorp_TcpStream* blorp_tcp_stream_from_open_fd(int raw_fd)";
      "blorp_TcpListener* blorp_tcp_listener_from_fd(long fd)";
      "blorp_TcpStream* blorp_tcp_stream_from_fd(long fd)";
      "blorp_Result* blorp_tcp_listen(blorp_String* host, long port, long \
       backlog)";
      "blorp_Result* blorp_tcp_accept(blorp_TcpListener* listener)";
      "blorp_Result* blorp_tcp_read(blorp_TcpStream* stream, long max_bytes)";
    ]
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime TCP handle model: " ^ needle)
        true
        (contains_substring runtime needle))
    required_runtime;
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime_decl TCP handle ABI: " ^ needle)
        true
        (contains_substring runtime_decl needle))
    [
      "typedef struct blorp_TcpListener blorp_TcpListener;";
      "typedef struct blorp_TcpStream blorp_TcpStream;";
      "blorp_Result* blorp_tcp_accept(blorp_TcpListener* listener);";
      "blorp_Result* blorp_tcp_read(blorp_TcpStream* stream, long max_bytes);";
      "blorp_Result* blorp_tcp_write(blorp_TcpStream* stream, blorp_Bytes* \
       data);";
      "void blorp_tcp_close_listener(blorp_TcpListener* listener);";
      "void blorp_tcp_close_stream(blorp_TcpStream* stream);";
      "blorp_Result* blorp_tcp_local_port_listener(blorp_TcpListener* \
       listener);";
      "blorp_Result* blorp_tcp_local_port_stream(blorp_TcpStream* stream);";
      "blorp_TcpListener* blorp_tcp_listener_from_fd(long fd);";
      "blorp_TcpStream* blorp_tcp_stream_from_fd(long fd);";
    ];
  Alcotest.(check bool)
    "runtime_decl keeps TcpListener opaque" false
    (contains_substring runtime_decl "struct blorp_TcpListener {");
  Alcotest.(check bool)
    "runtime_decl keeps TcpStream opaque" false
    (contains_substring runtime_decl "struct blorp_TcpStream {")

let test_tcp_numeric_host_resolution_policy_is_explicit () =
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime TCP numeric host policy: " ^ needle)
        true
        (contains_substring runtime needle))
    [
      "static bool blorp_tcp_host_is_numeric";
      "static blorp_Result* blorp_tcp_copy_host";
      "host too long";
      "static int blorp_tcp_getaddrinfo";
      "lookup_host = NULL";
      "hints->ai_flags |= AI_NUMERICHOST";
      "getaddrinfo(lookup_host, port, hints, res)";
      "blorp_tcp_getaddrinfo(host_buf, port_buf, &hints, &res)";
    ]

let test_tcp_timeouts_are_runtime_deadlines () =
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime TCP timeout deadline policy: " ^ needle)
        true
        (contains_substring runtime needle))
    [
      "static bool blorp_tcp_timeout_ms_is_valid";
      "static blorp_Result* blorp_tcp_set_timeout_inner";
      "inner->default_timeout_ms = ms";
      "tcp set_timeout: invalid timeout";
    ];
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime TCP timeout avoids kernel option: " ^ needle)
        false
        (contains_substring runtime needle))
    [ "blorp_tcp_set_timeout_fd"; "SO_RCVTIMEO"; "SO_SNDTIMEO" ]

let test_tcp_write_after_peer_close_does_not_sigpipe () =
  let project_root = Filename.dirname startup_std_dir in
  let runtime_path = Filename.concat project_root "compiler/lib/runtime.c" in
  let minicoro_path = Filename.concat project_root "compiler/lib/minicoro.h" in
  let runtime = read_file runtime_path in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime TCP SIGPIPE policy: " ^ needle)
        true
        (contains_substring runtime needle))
    [
      "BLORP_TCP_SEND_FLAGS";
      "static void blorp_tcp_suppress_sigpipe";
      "SO_NOSIGPIPE";
      "blorp_tcp_suppress_sigpipe(raw_fd)";
      "BLORP_TCP_SEND_FLAGS);";
    ];
  let c_path = Filename.temp_file "blorp-tcp-sigpipe-smoke-" ".c" in
  let exe_path = c_path ^ ".out" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists c_path then Sys.remove c_path;
      if Sys.file_exists exe_path then Sys.remove exe_path)
    (fun () ->
      write_file c_path
        (Printf.sprintf
           "#define MINICORO_IMPL\n\
            #include %S\n\
            #include %S\n\
            int main(void) {\n\
           \    int fds[2];\n\
           \    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return 10;\n\
           \    blorp_TcpStream* writer = blorp_tcp_stream_from_fd(fds[0]);\n\
           \    blorp_TcpStream* peer = blorp_tcp_stream_from_fd(fds[1]);\n\
           \    blorp_tcp_close_stream(peer);\n\
           \    blorp_release((void*)peer);\n\
           \    blorp_Bytes* bytes = blorp_bytes_new(1);\n\
           \    bytes->data[0] = 42;\n\
           \    blorp_Result* result = blorp_tcp_write(writer, bytes);\n\
           \    int ok = result && result->tag == BLORP_TAG_ERR;\n\
           \    if (result) blorp_release((void*)result);\n\
           \    blorp_release((void*)bytes);\n\
           \    blorp_tcp_close_stream(writer);\n\
           \    blorp_release((void*)writer);\n\
           \    return ok ? 0 : 20;\n\
            }\n"
           minicoro_path runtime_path);
      let compile_code, compile_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30) "cc"
          [
            "-std=c11";
            "-O0";
            "-Wno-unused-function";
            "-Wno-unused-parameter";
            "-o";
            exe_path;
            c_path;
            "-lm";
            "-lpthread";
          ]
      in
      if compile_code <> 0 then
        Alcotest.failf "TCP SIGPIPE C compile smoke failed:\n%s" compile_output;
      let run_code, run_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30)
          exe_path []
      in
      if run_code <> 0 then
        Alcotest.failf
          "TCP write after peer close should return Err instead of terminating \
           or succeeding (exit %d):\n\
           %s"
          run_code run_output)

let test_tcp_write_rejects_null_buffer () =
  let project_root = Filename.dirname startup_std_dir in
  let runtime_path = Filename.concat project_root "compiler/lib/runtime.c" in
  let minicoro_path = Filename.concat project_root "compiler/lib/minicoro.h" in
  let c_path = Filename.temp_file "blorp-tcp-null-write-smoke-" ".c" in
  let exe_path = c_path ^ ".out" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists c_path then Sys.remove c_path;
      if Sys.file_exists exe_path then Sys.remove exe_path)
    (fun () ->
      write_file c_path
        (Printf.sprintf
           "#define MINICORO_IMPL\n\
            #include %S\n\
            #include %S\n\
            int main(void) {\n\
           \    int fds[2];\n\
           \    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return 10;\n\
           \    blorp_TcpStream* stream = blorp_tcp_stream_from_fd(fds[0]);\n\
           \    blorp_Result* result = blorp_tcp_write(stream, NULL);\n\
           \    int ok = result && result->tag == BLORP_TAG_ERR;\n\
           \    if (result) blorp_release((void*)result);\n\
           \    blorp_tcp_close_stream(stream);\n\
           \    blorp_release((void*)stream);\n\
           \    close(fds[1]);\n\
           \    return ok ? 0 : 20;\n\
            }\n"
           minicoro_path runtime_path);
      let compile_code, compile_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30) "cc"
          [
            "-std=c11";
            "-O0";
            "-Wno-unused-function";
            "-Wno-unused-parameter";
            "-o";
            exe_path;
            c_path;
            "-lm";
            "-lpthread";
          ]
      in
      if compile_code <> 0 then
        Alcotest.failf "TCP null-write C compile smoke failed:\n%s"
          compile_output;
      let run_code, run_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30)
          exe_path []
      in
      if run_code <> 0 then
        Alcotest.failf "TCP write should reject null Bytes (exit %d):\n%s"
          run_code run_output)

let test_tcp_write_rejects_malformed_bytes () =
  let project_root = Filename.dirname startup_std_dir in
  let runtime_path = Filename.concat project_root "compiler/lib/runtime.c" in
  let minicoro_path = Filename.concat project_root "compiler/lib/minicoro.h" in
  let c_path = Filename.temp_file "blorp-tcp-malformed-write-smoke-" ".c" in
  let exe_path = c_path ^ ".out" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists c_path then Sys.remove c_path;
      if Sys.file_exists exe_path then Sys.remove exe_path)
    (fun () ->
      write_file c_path
        (Printf.sprintf
           "#define MINICORO_IMPL\n\
            #include %S\n\
            #include %S\n\
            static int err_contains(blorp_Result* result, const char* needle) {\n\
           \    if (!result || result->tag != BLORP_TAG_ERR) return 0;\n\
           \    blorp_String* err = (blorp_String*)result->data.Err.field0;\n\
           \    return err && strstr(err->data, needle) != NULL;\n\
            }\n\
            int main(void) {\n\
           \    int fds[2];\n\
           \    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return 10;\n\
           \    blorp_TcpStream* stream = blorp_tcp_stream_from_fd(fds[0]);\n\
           \    blorp_Bytes* negative = blorp_bytes_new(1);\n\
           \    negative->len = -1;\n\
           \    blorp_Result* result = blorp_tcp_write(stream, negative);\n\
           \    int ok = err_contains(result, \"invalid data\");\n\
           \    if (result) blorp_release((void*)result);\n\
           \    blorp_release((void*)negative);\n\
           \    if (!ok) {\n\
           \        blorp_tcp_close_stream(stream);\n\
           \        blorp_release((void*)stream);\n\
           \        close(fds[1]);\n\
           \        return 20;\n\
           \    }\n\
           \    blorp_Bytes* oversized = blorp_bytes_new(1);\n\
           \    oversized->len = oversized->capacity + 1;\n\
           \    result = blorp_tcp_write(stream, oversized);\n\
           \    ok = err_contains(result, \"invalid data\");\n\
           \    if (result) blorp_release((void*)result);\n\
           \    blorp_release((void*)oversized);\n\
           \    blorp_tcp_close_stream(stream);\n\
           \    blorp_release((void*)stream);\n\
           \    close(fds[1]);\n\
           \    return ok ? 0 : 30;\n\
            }\n"
           minicoro_path runtime_path);
      let compile_code, compile_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30) "cc"
          [
            "-std=c11";
            "-O0";
            "-Wno-unused-function";
            "-Wno-unused-parameter";
            "-o";
            exe_path;
            c_path;
            "-lm";
            "-lpthread";
          ]
      in
      if compile_code <> 0 then
        Alcotest.failf "TCP malformed-write C compile smoke failed:\n%s"
          compile_output;
      let run_code, run_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30)
          exe_path []
      in
      if run_code <> 0 then
        Alcotest.failf
          "TCP write should reject malformed Bytes before send (exit %d):\n%s"
          run_code run_output)

let test_tcp_read_rejects_oversized_buffer () =
  let project_root = Filename.dirname startup_std_dir in
  let runtime_path = Filename.concat project_root "compiler/lib/runtime.c" in
  let minicoro_path = Filename.concat project_root "compiler/lib/minicoro.h" in
  let c_path = Filename.temp_file "blorp-tcp-oversized-read-smoke-" ".c" in
  let exe_path = c_path ^ ".out" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists c_path then Sys.remove c_path;
      if Sys.file_exists exe_path then Sys.remove exe_path)
    (fun () ->
      write_file c_path
        (Printf.sprintf
           "#define MINICORO_IMPL\n\
            #include %S\n\
            #include %S\n\
            int main(void) {\n\
           \    int fds[2];\n\
           \    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return 10;\n\
           \    blorp_TcpStream* stream = blorp_tcp_stream_from_fd(fds[0]);\n\
           \    blorp_Result* result = blorp_tcp_read(stream, LONG_MAX);\n\
           \    int ok = result && result->tag == BLORP_TAG_ERR;\n\
           \    if (result) blorp_release((void*)result);\n\
           \    blorp_tcp_close_stream(stream);\n\
           \    blorp_release((void*)stream);\n\
           \    close(fds[1]);\n\
           \    return ok ? 0 : 20;\n\
            }\n"
           minicoro_path runtime_path);
      let compile_code, compile_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30) "cc"
          [
            "-std=c11";
            "-O0";
            "-Wno-unused-function";
            "-Wno-unused-parameter";
            "-o";
            exe_path;
            c_path;
            "-lm";
            "-lpthread";
          ]
      in
      if compile_code <> 0 then
        Alcotest.failf "TCP oversized-read C compile smoke failed:\n%s"
          compile_output;
      let run_code, run_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30)
          exe_path []
      in
      if run_code <> 0 then
        Alcotest.failf
          "TCP read should reject oversized max_bytes before allocation (exit \
           %d):\n\
           %s"
          run_code run_output)

let test_tcp_fd_wrappers_reject_invalid_fd () =
  let project_root = Filename.dirname startup_std_dir in
  let runtime_path = Filename.concat project_root "compiler/lib/runtime.c" in
  let minicoro_path = Filename.concat project_root "compiler/lib/minicoro.h" in
  let c_path = Filename.temp_file "blorp-tcp-invalid-fd-smoke-" ".c" in
  let exe_path = c_path ^ ".out" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists c_path then Sys.remove c_path;
      if Sys.file_exists exe_path then Sys.remove exe_path)
    (fun () ->
      write_file c_path
        (Printf.sprintf
           "#define MINICORO_IMPL\n\
            #include %S\n\
            #include %S\n\
            int main(void) {\n\
           \    int fds[2];\n\
           \    if (pipe(fds) != 0) return 10;\n\
           \    int closed_fd = fds[0];\n\
           \    close(fds[0]);\n\
           \    close(fds[1]);\n\
           \    int stream_pipe[2];\n\
           \    if (pipe(stream_pipe) != 0) return 11;\n\
           \    int listener_pipe[2];\n\
           \    if (pipe(listener_pipe) != 0) return 12;\n\
           \    blorp_TcpStream* negative_stream = blorp_tcp_stream_from_fd(-1);\n\
           \    blorp_TcpStream* oversized_stream = \
            blorp_tcp_stream_from_fd(LONG_MAX);\n\
           \    blorp_TcpStream* closed_stream = \
            blorp_tcp_stream_from_fd(closed_fd);\n\
           \    blorp_TcpStream* pipe_stream = \
            blorp_tcp_stream_from_fd(stream_pipe[0]);\n\
           \    blorp_TcpListener* negative_listener = \
            blorp_tcp_listener_from_fd(-1);\n\
           \    blorp_TcpListener* oversized_listener = \
            blorp_tcp_listener_from_fd(LONG_MAX);\n\
           \    blorp_TcpListener* closed_listener = \
            blorp_tcp_listener_from_fd(closed_fd);\n\
           \    blorp_TcpListener* pipe_listener = \
            blorp_tcp_listener_from_fd(listener_pipe[0]);\n\
           \    int ok = negative_stream == NULL && oversized_stream == NULL \
            && closed_stream == NULL && negative_listener == NULL && \
            oversized_listener == NULL && closed_listener == NULL && \
            pipe_stream == NULL && pipe_listener == NULL;\n\
           \    if (closed_stream) blorp_release((void*)closed_stream);\n\
           \    if (closed_listener) blorp_release((void*)closed_listener);\n\
           \    if (pipe_stream) blorp_release((void*)pipe_stream);\n\
           \    else close(stream_pipe[0]);\n\
           \    close(stream_pipe[1]);\n\
           \    if (pipe_listener) blorp_release((void*)pipe_listener);\n\
           \    else close(listener_pipe[0]);\n\
           \    close(listener_pipe[1]);\n\
           \    return ok ? 0 : 20;\n\
            }\n"
           minicoro_path runtime_path);
      let compile_code, compile_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30) "cc"
          [
            "-std=c11";
            "-O0";
            "-Wno-unused-function";
            "-Wno-unused-parameter";
            "-o";
            exe_path;
            c_path;
            "-lm";
            "-lpthread";
          ]
      in
      if compile_code <> 0 then
        Alcotest.failf "TCP invalid-fd C compile smoke failed:\n%s"
          compile_output;
      let run_code, run_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30)
          exe_path []
      in
      if run_code <> 0 then
        Alcotest.failf
          "TCP fd wrappers should reject invalid fd values (exit %d):\n%s"
          run_code run_output)

let test_tcp_owned_result_rejects_null_handle () =
  let project_root = Filename.dirname startup_std_dir in
  let runtime_path = Filename.concat project_root "compiler/lib/runtime.c" in
  let minicoro_path = Filename.concat project_root "compiler/lib/minicoro.h" in
  let c_path = Filename.temp_file "blorp-tcp-null-handle-result-smoke-" ".c" in
  let exe_path = c_path ^ ".out" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists c_path then Sys.remove c_path;
      if Sys.file_exists exe_path then Sys.remove exe_path)
    (fun () ->
      write_file c_path
        (Printf.sprintf
           "#define MINICORO_IMPL\n\
            #include %S\n\
            #include %S\n\
            static int err_contains(blorp_Result* result, const char* needle) {\n\
           \    if (!result || result->tag != BLORP_TAG_ERR) return 0;\n\
           \    blorp_String* err = (blorp_String*)result->data.Err.field0;\n\
           \    return err && strstr(err->data, needle) != NULL;\n\
            }\n\
            int main(void) {\n\
           \    blorp_Result* result = tcp_owned_ok(NULL);\n\
           \    int ok = err_contains(result, \"invalid handle\");\n\
           \    if (result) blorp_release((void*)result);\n\
           \    return ok ? 0 : 20;\n\
            }\n"
           minicoro_path runtime_path);
      let compile_code, compile_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30) "cc"
          [
            "-std=c11";
            "-O0";
            "-Wno-unused-function";
            "-Wno-unused-parameter";
            "-o";
            exe_path;
            c_path;
            "-lm";
            "-lpthread";
          ]
      in
      if compile_code <> 0 then
        Alcotest.failf "TCP null-handle-result C compile smoke failed:\n%s"
          compile_output;
      let run_code, run_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30)
          exe_path []
      in
      if run_code <> 0 then
        Alcotest.failf
          "TCP owned Result helper should reject null handles (exit %d):\n%s"
          run_code run_output)

let test_tcp_fd_wrappers_normalize_socket_flags () =
  let project_root = Filename.dirname startup_std_dir in
  let runtime_path = Filename.concat project_root "compiler/lib/runtime.c" in
  let minicoro_path = Filename.concat project_root "compiler/lib/minicoro.h" in
  let c_path = Filename.temp_file "blorp-tcp-fd-wrapper-flags-smoke-" ".c" in
  let exe_path = c_path ^ ".out" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists c_path then Sys.remove c_path;
      if Sys.file_exists exe_path then Sys.remove exe_path)
    (fun () ->
      write_file c_path
        (Printf.sprintf
           "#define MINICORO_IMPL\n\
            #include %S\n\
            #include %S\n\
            static int fd_is_nonblocking(int fd) {\n\
           \    int flags = fcntl(fd, F_GETFL, 0);\n\
           \    return flags >= 0 && (flags & O_NONBLOCK) != 0;\n\
            }\n\
            static int make_listener_fd(void) {\n\
           \    int fd = socket(AF_INET, SOCK_STREAM, 0);\n\
           \    if (fd < 0) return -1;\n\
           \    int opt = 1;\n\
           \    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));\n\
           \    struct sockaddr_in addr;\n\
           \    memset(&addr, 0, sizeof(addr));\n\
           \    addr.sin_family = AF_INET;\n\
           \    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);\n\
           \    addr.sin_port = 0;\n\
           \    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {\n\
           \        close(fd);\n\
           \        return -1;\n\
           \    }\n\
           \    if (listen(fd, 1) != 0) {\n\
           \        close(fd);\n\
           \        return -1;\n\
           \    }\n\
           \    return fd;\n\
            }\n\
            int main(void) {\n\
           \    int fds[2];\n\
           \    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return 10;\n\
           \    blorp_TcpStream* stream = blorp_tcp_stream_from_fd(fds[0]);\n\
           \    if (!stream) {\n\
           \        close(fds[0]);\n\
           \        close(fds[1]);\n\
           \        return 20;\n\
           \    }\n\
           \    int stream_ok = fd_is_nonblocking(fds[0]);\n\
           \    blorp_release((void*)stream);\n\
           \    close(fds[1]);\n\
           \    int listener_fd = make_listener_fd();\n\
           \    if (listener_fd < 0) return 30;\n\
           \    blorp_TcpListener* listener = \
            blorp_tcp_listener_from_fd(listener_fd);\n\
           \    if (!listener) {\n\
           \        close(listener_fd);\n\
           \        return 40;\n\
           \    }\n\
           \    int listener_ok = fd_is_nonblocking(listener_fd);\n\
           \    blorp_release((void*)listener);\n\
           \    return stream_ok && listener_ok ? 0 : 50;\n\
            }\n"
           minicoro_path runtime_path);
      let compile_code, compile_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30) "cc"
          [
            "-std=c11";
            "-O0";
            "-Wno-unused-function";
            "-Wno-unused-parameter";
            "-o";
            exe_path;
            c_path;
            "-lm";
            "-lpthread";
          ]
      in
      if compile_code <> 0 then
        Alcotest.failf "TCP fd-wrapper-flags C compile smoke failed:\n%s"
          compile_output;
      let run_code, run_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30)
          exe_path []
      in
      if run_code <> 0 then
        Alcotest.failf
          "TCP fd wrappers should normalize socket fds to nonblocking mode \
           (exit %d):\n\
           %s"
          run_code run_output)

let test_tcp_host_copy_rejects_malformed_string () =
  let project_root = Filename.dirname startup_std_dir in
  let runtime_path = Filename.concat project_root "compiler/lib/runtime.c" in
  let minicoro_path = Filename.concat project_root "compiler/lib/minicoro.h" in
  let c_path = Filename.temp_file "blorp-tcp-malformed-host-smoke-" ".c" in
  let exe_path = c_path ^ ".out" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists c_path then Sys.remove c_path;
      if Sys.file_exists exe_path then Sys.remove exe_path)
    (fun () ->
      write_file c_path
        (Printf.sprintf
           "#define MINICORO_IMPL\n\
            #include %S\n\
            #include %S\n\
            static int err_contains(blorp_Result* result, const char* needle) {\n\
           \    if (!result || result->tag != BLORP_TAG_ERR) return 0;\n\
           \    blorp_String* err = (blorp_String*)result->data.Err.field0;\n\
           \    return err && strstr(err->data, needle) != NULL;\n\
            }\n\
            int main(void) {\n\
           \    blorp_String* host = blorp_string_create(\"127.0.0.1\");\n\
           \    host->len = host->capacity + 1;\n\
           \    blorp_Result* result = blorp_tcp_listen(host, 0, 1);\n\
           \    int ok = err_contains(result, \"invalid host\");\n\
           \    if (result) blorp_release((void*)result);\n\
           \    blorp_release((void*)host);\n\
           \    return ok ? 0 : 20;\n\
            }\n"
           minicoro_path runtime_path);
      let compile_code, compile_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30) "cc"
          [
            "-std=c11";
            "-O0";
            "-Wno-unused-function";
            "-Wno-unused-parameter";
            "-o";
            exe_path;
            c_path;
            "-lm";
            "-lpthread";
          ]
      in
      if compile_code <> 0 then
        Alcotest.failf "TCP malformed-host C compile smoke failed:\n%s"
          compile_output;
      let run_code, run_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30)
          exe_path []
      in
      if run_code <> 0 then
        Alcotest.failf
          "TCP host copy should reject malformed String bounds (exit %d):\n%s"
          run_code run_output)

let test_tcp_and_reactor_fds_are_close_on_exec () =
  let project_root = Filename.dirname startup_std_dir in
  let runtime_path = Filename.concat project_root "compiler/lib/runtime.c" in
  let minicoro_path = Filename.concat project_root "compiler/lib/minicoro.h" in
  let runtime = read_file runtime_path in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime close-on-exec policy: " ^ needle)
        true
        (contains_substring runtime needle))
    [
      "static int blorp_runtime_set_cloexec(int fd)";
      "static int blorp_runtime_socket_cloexec(";
      "static int blorp_runtime_accept_cloexec(";
      "static int blorp_runtime_pipe_cloexec_nonblock(int fds[2])";
      "blorp_runtime_set_cloexec(raw_fd)";
      "blorp_runtime_socket_cloexec(res->ai_family, res->ai_socktype, \
       res->ai_protocol)";
      "blorp_runtime_accept_cloexec(";
      "blorp_runtime_pipe_cloexec_nonblock(control_fds)";
    ];
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime avoids open-coded TCP/reactor fd creation: " ^ needle)
        false
        (contains_substring runtime needle))
    [
      "int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol)";
      "int client_fd = accept((int)server_fd";
      "if (pipe(control_fds) != 0)";
    ];
  let c_path = Filename.temp_file "blorp-tcp-cloexec-smoke-" ".c" in
  let exe_path = c_path ^ ".out" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists c_path then Sys.remove c_path;
      if Sys.file_exists exe_path then Sys.remove exe_path)
    (fun () ->
      write_file c_path
        (Printf.sprintf
           "#define MINICORO_IMPL\n\
            #include %S\n\
            #include %S\n\
            static int has_cloexec(int fd) {\n\
           \    int flags = fcntl(fd, F_GETFD, 0);\n\
           \    return flags >= 0 && (flags & FD_CLOEXEC) != 0;\n\
            }\n\
            static int is_nonblocking(int fd) {\n\
           \    int flags = fcntl(fd, F_GETFL, 0);\n\
           \    return flags >= 0 && (flags & O_NONBLOCK) != 0;\n\
            }\n\
            int main(void) {\n\
           \    int fds[2];\n\
           \    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return 10;\n\
           \    blorp_TcpStream* stream = blorp_tcp_stream_from_fd(fds[0]);\n\
           \    if (!has_cloexec(fds[0])) return 20;\n\
           \    blorp_release((void*)stream);\n\
           \    close(fds[1]);\n\
           \    int socket_fd = blorp_runtime_socket_cloexec(AF_UNIX, \
            SOCK_STREAM, 0);\n\
           \    if (socket_fd < 0 || !has_cloexec(socket_fd)) return 25;\n\
           \    close(socket_fd);\n\
           \    int pipe_fds[2];\n\
           \    if (blorp_runtime_pipe_cloexec_nonblock(pipe_fds) != 0) return \
            26;\n\
           \    int pipe_ok = has_cloexec(pipe_fds[0]) && \
            has_cloexec(pipe_fds[1]) && is_nonblocking(pipe_fds[0]) && \
            is_nonblocking(pipe_fds[1]);\n\
           \    close(pipe_fds[0]);\n\
           \    close(pipe_fds[1]);\n\
           \    if (!pipe_ok) return 27;\n\
           \    if (blorp_io_reactor_start() != 0) return 30;\n\
           \    int control_read = __blorp_io_reactor.control_read_fd;\n\
           \    int control_write = __blorp_io_reactor.control_write_fd;\n\
           \    int ok = has_cloexec(control_read) && \
            has_cloexec(control_write);\n\
           \    blorp_io_reactor_shutdown();\n\
           \    return ok ? 0 : 40;\n\
            }\n"
           minicoro_path runtime_path);
      let compile_code, compile_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30) "cc"
          [
            "-std=c11";
            "-O0";
            "-Wno-unused-function";
            "-Wno-unused-parameter";
            "-o";
            exe_path;
            c_path;
            "-lm";
            "-lpthread";
          ]
      in
      if compile_code <> 0 then
        Alcotest.failf "TCP close-on-exec C compile smoke failed:\n%s"
          compile_output;
      let run_code, run_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30)
          exe_path []
      in
      if run_code <> 0 then
        Alcotest.failf "TCP/reactor fds should be close-on-exec (exit %d):\n%s"
          run_code run_output)

let test_sanitize_runtime_options_account_for_fiber_stacks () =
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime sanitizer should not globally mask stack checks: " ^ needle)
        false
        (contains_substring runtime needle))
    [
      "const char* __asan_default_options(void)";
      "detect_stack_use_after_return=0";
      "detect_stack_use_after_scope=0";
    ];
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime sanitizer fiber-stack option: " ^ needle)
        true
        (contains_substring runtime needle))
    [
      "static size_t blorp_fiber_alloc_pool_limit(void)";
      "ASan tracks stack redzones across fiber switches";
      "return 0;\n#else\n    return FIBER_ALLOC_POOL_LIMIT;";
      "ASan tracks fiber stack switches itself";
      "Use ordinary heap storage in";
    ]

let test_sanitize_runtime_env_preserves_caller_options () =
  let old = Sys.getenv_opt "ASAN_OPTIONS" in
  let restore () =
    match old with
    | Some value -> Unix.putenv "ASAN_OPTIONS" value
    | None -> Unix.putenv "ASAN_OPTIONS" ""
  in
  Fun.protect ~finally:restore (fun () ->
      Unix.putenv "ASAN_OPTIONS" "halt_on_error=0";
      Blorp.Test_runner.with_sanitizer_runtime_env (fun () ->
          let value =
            match Sys.getenv_opt "ASAN_OPTIONS" with
            | Some v -> v
            | None -> Alcotest.fail "ASAN_OPTIONS should be set"
          in
          Alcotest.(check string)
            "sanitizer runtime env preserves caller options" "halt_on_error=0"
            value;
          Alcotest.(check bool)
            "sanitizer runtime env does not disable stack-use-after-return"
            false
            (contains_substring value "detect_stack_use_after_return=0");
          Alcotest.(check bool)
            "sanitizer runtime env does not disable stack-use-after-scope" false
            (contains_substring value "detect_stack_use_after_scope=0")))

let test_io_reactor_runtime_skeleton_is_explicit () =
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let runtime_decl =
    read_first_existing
      [
        "compiler/lib/runtime_decl.c";
        "../lib/runtime_decl.c";
        "lib/runtime_decl.c";
      ]
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime IO reactor skeleton: " ^ needle)
        true
        (contains_substring runtime needle))
    [
      "typedef enum {";
      "BLORP_IO_BACKEND_KQUEUE";
      "BLORP_IO_BACKEND_EPOLL";
      "BLORP_IO_BACKEND_POLL";
      "typedef struct blorp_IoReactor";
      "static blorp_IoBackendKind blorp_io_reactor_active_backend(void)";
      "return BLORP_IO_BACKEND_POLL;";
      "static int blorp_io_reactor_register_inner(";
      "static int blorp_io_reactor_update_interest(";
      "static int blorp_io_reactor_unregister_inner(";
      "static void blorp_io_reactor_wake_control(void)";
      "static void* blorp_io_reactor_thread(void* arg)";
      "int blorp_io_reactor_start(void)";
      "void blorp_io_reactor_shutdown(void)";
      "int blorp_io_reactor_smoke_test(void)";
    ];
  Alcotest.(check bool)
    "runtime_decl exposes reactor smoke ABI" true
    (contains_substring runtime_decl "int blorp_io_reactor_smoke_test(void);")

let test_io_reactor_c_compile_smoke () =
  let project_root = Filename.dirname startup_std_dir in
  let runtime_path = Filename.concat project_root "compiler/lib/runtime.c" in
  let minicoro_path = Filename.concat project_root "compiler/lib/minicoro.h" in
  let c_path = Filename.temp_file "blorp-io-reactor-smoke-" ".c" in
  let exe_path = c_path ^ ".out" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists c_path then Sys.remove c_path;
      if Sys.file_exists exe_path then Sys.remove exe_path)
    (fun () ->
      write_file c_path
        (Printf.sprintf
           "#define MINICORO_IMPL\n\
            #include %S\n\
            #include %S\n\
            int main(void) {\n\
           \    return blorp_io_reactor_smoke_test == 0;\n\
            }\n"
           minicoro_path runtime_path);
      let compile_code, compile_output =
        Blorp.Test_runner.run_process_capture_timeout ~timeout:(Some 30) "cc"
          [
            "-std=c11";
            "-O0";
            "-Wno-unused-function";
            "-Wno-unused-parameter";
            "-o";
            exe_path;
            c_path;
            "-lm";
            "-lpthread";
          ]
      in
      if compile_code <> 0 then
        Alcotest.failf "IO reactor C compile smoke failed:\n%s" compile_output)

let builtin_runtime_option_returns_in_std () =
  let reg = Blorp.Codegen_types.create_registry () in
  let meta = Blorp.Core_type_layout.metadata_for_registry reg in
  all_std_blorp_files ()
  |> List.concat_map (fun path ->
      match Blorp.Modules.parse_source ~filename:path (read_file path) with
      | Error err -> Alcotest.fail err.message
      | Ok decls ->
          List.filter_map
            (function
              | {
                  Blorp.Ast.decl_desc =
                    Blorp.Ast.DFunc
                      {
                        func_name = Some func_name;
                        func_return_type = Some return_ty;
                        func_body =
                          Blorp.Ast.FuncBuiltinBody
                            (Blorp.Ast.BuiltinRuntime symbol, _);
                        _;
                      };
                  _;
                } -> (
                  match optimized_option_policy_c_return reg meta return_ty with
                  | Some expected_c_return ->
                      Some (path, func_name, symbol, expected_c_return)
                  | None -> None)
              | _ -> None)
            decls)

let test_optimized_option_runtime_builtins_have_matching_c_abi () =
  let runtime_decl =
    read_first_existing
      [
        "compiler/lib/runtime_decl.c";
        "../lib/runtime_decl.c";
        "lib/runtime_decl.c";
      ]
  in
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let reg = Blorp.Codegen_types.create_registry () in
  let meta = Blorp.Core_type_layout.metadata_for_registry reg in
  let known_symbols =
    optimized_option_abi_cases
    |> List.map (fun case -> case.symbol)
    |> List.sort_uniq String.compare
  in
  let missing_direct_cases =
    builtin_runtime_option_returns_in_std ()
    |> List.filter (fun (_path, _func_name, symbol, _expected_c_return) ->
        not (List.mem symbol known_symbols))
  in
  if missing_direct_cases <> [] then
    Alcotest.failf
      "Direct stdlib runtime builtins returning optimized Option need explicit \
       ABI cases:\n\
      \  %s"
      (missing_direct_cases
      |> List.map (fun (path, func_name, symbol, expected_c_return) ->
          Printf.sprintf "%s:%s -> %s (%s)" path func_name symbol
            expected_c_return)
      |> String.concat "\n  ");
  List.iter
    (fun case ->
      let return_c_ty = runtime_return_for_case reg meta case in
      let signature =
        Printf.sprintf "%s %s(%s)" return_c_ty case.symbol case.params
      in
      Alcotest.(check bool)
        ("runtime_decl " ^ case.symbol)
        true
        (contains_substring runtime_decl (signature ^ ";"));
      match case.definition_check with
      | Check_runtime_definition ->
          Alcotest.(check bool)
            ("runtime " ^ case.symbol) true
            (contains_substring runtime signature)
      | Decl_only -> ())
    optimized_option_abi_cases

let suite =
  [
    ( "prelude_entries",
      [
        Alcotest.test_case "all prelude codegen entries are env-visible" `Quick
          test_prelude_entries_registered;
        Alcotest.test_case "exception list not stale" `Quick
          test_exception_list_not_stale;
        Alcotest.test_case "builtin effect metadata classifies typechecker sets"
          `Quick test_builtin_effect_metadata_classifies_typechecker_sets;
        Alcotest.test_case
          "builtin call-effect metadata distinguishes waiting modes" `Quick
          test_builtin_call_effect_metadata_distinguishes_waiting_modes;
        Alcotest.test_case "builtin call-effect metadata maps runtime symbols"
          `Quick test_builtin_call_effect_metadata_maps_runtime_symbols;
        Alcotest.test_case "type metadata classifies typechecker policy" `Quick
          test_type_metadata_classifies_typechecker_policy;
        Alcotest.test_case
          "type metadata separates operator and to_string fallbacks" `Quick
          test_type_metadata_splits_operator_and_to_string_fallbacks;
        Alcotest.test_case "builtin metadata classifies special inference"
          `Quick test_builtin_metadata_classifies_special_inference;
        Alcotest.test_case "builtin metadata registry integrity" `Quick
          test_builtin_metadata_registry_integrity;
        Alcotest.test_case
          "std impure runtime builtins have call-effect metadata" `Quick
          test_std_impure_runtime_builtins_have_call_effect_metadata;
        Alcotest.test_case
          "std impure runtime symbols have call-effect metadata" `Quick
          test_std_impure_runtime_symbols_have_call_effect_metadata;
        Alcotest.test_case
          "list IR functions are not shadowed by codegen builtins" `Quick
          test_list_ir_functions_not_shadowed_by_codegen_builtins;
        Alcotest.test_case "builtin lookup uses exact module paths" `Quick
          test_builtin_lookup_uses_exact_module_paths;
        Alcotest.test_case "list IR HOFs have no runtime C ABI" `Quick
          test_list_ir_hofs_have_no_runtime_c_abi;
        Alcotest.test_case "fiber intrusive links are role-specific" `Quick
          test_fiber_intrusive_links_are_role_specific;
        Alcotest.test_case "std source dir initialized from config" `Quick
          test_std_source_dir_initialized_from_config;
        Alcotest.test_case "list join uses IR string_append" `Quick
          test_list_join_uses_ir_string_append;
        Alcotest.test_case "builder module removed from std" `Quick
          test_builder_module_removed_from_std;
        Alcotest.test_case "public ABI types have std anchors" `Quick
          test_public_abi_types_have_std_anchors;
        Alcotest.test_case "TCP handle ABI types are managed runtime pointers"
          `Quick test_tcp_handle_abi_types_are_managed_runtime_pointers;
        Alcotest.test_case "TCP runtime handle model is explicit" `Quick
          test_tcp_runtime_handle_model_is_explicit;
        Alcotest.test_case "TCP numeric host resolution policy is explicit"
          `Quick test_tcp_numeric_host_resolution_policy_is_explicit;
        Alcotest.test_case "TCP timeouts are runtime deadlines" `Quick
          test_tcp_timeouts_are_runtime_deadlines;
        Alcotest.test_case "TCP write after peer close does not SIGPIPE" `Quick
          test_tcp_write_after_peer_close_does_not_sigpipe;
        Alcotest.test_case "TCP write rejects null buffer" `Quick
          test_tcp_write_rejects_null_buffer;
        Alcotest.test_case "TCP write rejects malformed Bytes" `Quick
          test_tcp_write_rejects_malformed_bytes;
        Alcotest.test_case "TCP read rejects oversized buffer" `Quick
          test_tcp_read_rejects_oversized_buffer;
        Alcotest.test_case "TCP fd wrappers reject invalid fd" `Quick
          test_tcp_fd_wrappers_reject_invalid_fd;
        Alcotest.test_case "TCP owned Result helper rejects null handle" `Quick
          test_tcp_owned_result_rejects_null_handle;
        Alcotest.test_case "TCP fd wrappers normalize socket flags" `Quick
          test_tcp_fd_wrappers_normalize_socket_flags;
        Alcotest.test_case "TCP host copy rejects malformed String" `Quick
          test_tcp_host_copy_rejects_malformed_string;
        Alcotest.test_case "TCP and reactor fds are close-on-exec" `Quick
          test_tcp_and_reactor_fds_are_close_on_exec;
        Alcotest.test_case "sanitize runtime options account for fiber stacks"
          `Quick test_sanitize_runtime_options_account_for_fiber_stacks;
        Alcotest.test_case "sanitize runtime env preserves caller options"
          `Quick test_sanitize_runtime_env_preserves_caller_options;
        Alcotest.test_case "IO reactor runtime skeleton is explicit" `Quick
          test_io_reactor_runtime_skeleton_is_explicit;
        Alcotest.test_case "IO reactor C compile smoke passes" `Quick
          test_io_reactor_c_compile_smoke;
        Alcotest.test_case "std foreign inventory is explicit" `Quick
          test_std_foreign_inventory_is_explicit;
        Alcotest.test_case "std native header inventory is explicit" `Quick
          test_std_native_header_inventory_is_explicit;
        Alcotest.test_case "pkg foreign inventory is explicit" `Quick
          test_pkg_foreign_inventory_is_explicit;
        Alcotest.test_case "pkg native header inventory is explicit" `Quick
          test_pkg_native_header_inventory_is_explicit;
        Alcotest.test_case "string appends have no legacy runtime C ABI" `Quick
          test_string_appends_have_no_legacy_runtime_c_abi;
        Alcotest.test_case "set source helpers have no runtime C ABI" `Quick
          test_set_source_helpers_have_no_runtime_c_abi;
        Alcotest.test_case "wide integer boxes are ARC-managed" `Quick
          test_wide_integer_boxes_are_arc_managed;
        Alcotest.test_case "sized integer conversions have runtime C ABI" `Quick
          test_sized_integer_conversions_have_runtime_c_abi;
        Alcotest.test_case
          "optimized Option runtime builtins have matching C ABI" `Quick
          test_optimized_option_runtime_builtins_have_matching_c_abi;
      ] );
  ]
