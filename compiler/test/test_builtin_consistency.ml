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
      Alcotest.(check bool) (name ^ " is impure") true (has_effect name Impure))
    [
      "print";
      "read_file";
      "write_file";
      "getenv";
      "send_timeout";
      "websocket_state_probe_for_test";
      "blorp_dns_resolve_raw";
    ];
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " is not impure") false (has_effect name Impure))
    [ "length"; "to_string"; "map" ];
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " is a parallel boundary")
        true
        (has_effect name Parallel_boundary))
    [ "parallel" ];
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " is not a parallel boundary")
        false
        (has_effect name Parallel_boundary))
    [ "map"; "print"; "length" ];
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " is a cancellation point")
        true
        (is_cancellation_point name))
    [
      "sleep";
      "yield_now";
      "send";
      "recv";
      "send_timeout";
      "recv_timeout";
      "send_timeout_attempt";
      "recv_timeout_attempt";
      "cancel_after_parked_for_test";
      "tls_state_probe_for_test";
      "blorp_tcp_accept";
      "blorp_tcp_connect";
      "blorp_tcp_read";
      "blorp_tcp_write";
      "blorp_tcp_accept_raw";
      "blorp_tcp_connect_loopback_raw";
      "blorp_tcp_connect_ip_raw";
      "blorp_tcp_connect_name_raw";
      "blorp_tcp_read_raw";
      "blorp_tcp_write_raw";
      "blorp_tcp_write_all_raw";
      "blorp_tls_connect_raw";
      "blorp_tls_read_raw";
      "blorp_tls_write_raw";
      "blorp_tls_write_all_raw";
      "blorp_websocket_connect_raw";
      "blorp_websocket_receive_raw";
      "blorp_websocket_send_text_raw";
      "blorp_websocket_send_binary_raw";
      "blorp_websocket_send_ping_raw";
      "blorp_websocket_send_pong_raw";
      "blorp_websocket_send_close_raw";
      "blorp_udp_send_to_wait_raw";
      "blorp_udp_send_to_wait_numeric_raw";
      "blorp_udp_recv_from_raw";
    ];
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " is not a cancellation point")
        false
        (is_cancellation_point name))
    [
      "channel";
      "try_send";
      "try_recv";
      "try_send_attempt";
      "try_recv_attempt";
      "seal";
      "read";
      "write";
      "blorp_tcp_listen";
      "blorp_dns_resolve_raw";
      "blorp_tcp_listen_loopback_raw";
      "blorp_tcp_listen_any_interface_raw";
      "blorp_tcp_listen_ip_raw";
      "blorp_tcp_local_port_listener_raw";
      "blorp_tcp_set_timeout_listener_raw";
      "blorp_udp_bind_raw";
      "blorp_udp_bind_numeric_raw";
      "blorp_udp_send_to_raw";
      "blorp_udp_send_to_numeric_raw";
      "parallel";
    ];
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " blocks an OS worker")
        true
        (is_os_worker_blocking name))
    [ "blorp_dns_resolve_raw" ];
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (name ^ " does not block an OS worker")
        false
        (is_os_worker_blocking name))
    [ "sleep"; "send"; "blorp_tcp_connect_loopback_raw"; "blorp_tls_read_raw" ]

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

let split_lines source = String.split_on_char '\n' source

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

let ends_with s suffix =
  let len = String.length s and suffix_len = String.length suffix in
  len >= suffix_len && String.sub s (len - suffix_len) suffix_len = suffix

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
  [ "compress.brp"; "crypto.brp"; "net/dns.brp"; "sqlite.brp" ]

let expected_pkg_native_header_files =
  [ "compress_ffi.h"; "crypto_ffi.h"; "net/dns_ffi.h"; "sqlite_ffi.h" ]

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
      ("object pool link", "struct blorp_Fiber* pool_next;");
      ("timer drain link", "struct blorp_Fiber* timer_drain_next;");
      ("channel waiter link", "struct blorp_ChannelFiberWaiter* next;");
      ("run queue pop uses run_next", "queue->head = f->run_next;");
      ("channel enqueue uses waiter next", "(*tail)->next = waiter");
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
       shared next pointer for run queues, object-pool reuse, and timer drain \
       batches. Channel waits use explicit waiter records with their own links."

let test_scheduler_debug_observability_has_named_hooks () =
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let required =
    [
      ("debug env gate", "BLORP_SCHEDULER_DEBUG");
      ("debug enabled helper", "blorp_scheduler_debug_enabled");
      ("fiber snapshot helper", "blorp_fiber_debug_snapshot");
      ("fiber invariant helper", "blorp_scheduler_debug_assert_fiber");
      ("debug abort helper", "blorp_scheduler_debug_abort_fiber");
      ("queued plus parked invariant", "queued and parked");
      ("running plus queued invariant", "running and queued");
    ]
  in
  List.iter
    (fun (name, needle) ->
      Alcotest.(check bool) name true (contains_substring runtime needle))
    required

let test_fiber_lifecycle_state_is_explicit () =
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let required =
    [
      ("fiber state enum", "typedef enum blorp_FiberState");
      ("free state", "BLORP_FIBER_FREE");
      ("created state", "BLORP_FIBER_CREATED");
      ("queued state", "BLORP_FIBER_QUEUED");
      ("running state", "BLORP_FIBER_RUNNING");
      ("parked state", "BLORP_FIBER_PARKED");
      ("completed state", "BLORP_FIBER_COMPLETED");
      ("fiber carries lifecycle state", "_Atomic int lifecycle_state;");
      ("state name helper", "blorp_fiber_state_debug_name");
      ("transition helper", "blorp_fiber_transition_state");
      ("mark created helper", "blorp_fiber_mark_created");
      ("mark queued helper", "blorp_fiber_mark_queued");
      ("mark running helper", "blorp_fiber_mark_running");
      ("mark parked helper", "blorp_fiber_mark_parked");
      ("mark completed helper", "blorp_fiber_mark_completed");
      ("mark free helper", "blorp_fiber_mark_free");
      ("recycled fibers clear coroutine pointer", "f->coro = NULL;");
      ("completed fibers clear coroutine pointer", "fiber->coro = NULL;");
    ]
  in
  List.iter
    (fun (name, needle) ->
      Alcotest.(check bool) name true (contains_substring runtime needle))
    required

let test_fiber_wake_cause_is_explicit () =
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let required =
    [
      ("fiber wake cause enum", "typedef enum blorp_FiberWakeCause");
      ("ready wake cause", "BLORP_WAKE_READY");
      ("timeout wake cause", "BLORP_WAKE_TIMEOUT");
      ("cancelled wake cause", "BLORP_WAKE_CANCELLED");
      ("closed wake cause", "BLORP_WAKE_CLOSED");
      ("sealed wake cause", "BLORP_WAKE_SEALED");
      ("fiber carries wake cause", "_Atomic int wake_cause;");
      ("wake cause name helper", "blorp_fiber_wake_cause_debug_name");
      ("wake helper", "blorp_fiber_wake");
      ( "cancel wake delegates to wake helper",
        "blorp_fiber_wake(f, BLORP_WAKE_CANCELLED" );
    ]
  in
  List.iter
    (fun (name, needle) ->
      Alcotest.(check bool) name true (contains_substring runtime needle))
    required;
  Alcotest.(check bool)
    "no separate cancel enqueue path" false
    (contains_substring runtime "blorp_fiber_enqueue_cancel_wake")

let test_fiber_wait_owner_is_explicit () =
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let required =
    [
      ("fiber wait owner enum", "typedef enum blorp_FiberWaitOwnerKind");
      ("no wait owner", "BLORP_WAIT_OWNER_NONE");
      ("sleep wait owner", "BLORP_WAIT_OWNER_SLEEP");
      ("task join wait owner", "BLORP_WAIT_OWNER_TASK_JOIN");
      ("channel send wait owner", "BLORP_WAIT_OWNER_CHANNEL_SEND");
      ("channel recv wait owner", "BLORP_WAIT_OWNER_CHANNEL_RECV");
      ("select wait owner", "BLORP_WAIT_OWNER_SELECT");
      ("io wait owner", "BLORP_WAIT_OWNER_IO");
      ("fiber carries wait owner", "_Atomic int wait_owner_kind;");
      ("fiber carries wait operation id", "_Atomic uint64_t wait_operation_id;");
      ("fiber carries timer wait operation id", "_Atomic uint64_t timer_wait_operation_id;");
      ("global wait operation counter", "__blorp_next_wait_operation_id");
      ("wait owner name helper", "blorp_fiber_wait_owner_debug_name");
      ("wait operation id helper", "blorp_fiber_current_wait_operation_id");
      ("begin wait helper", "blorp_fiber_begin_wait");
      ("clear wait helper", "blorp_fiber_clear_wait");
      ("snapshot includes wait owner", "wait_owner=%s");
      ("snapshot includes wait id", "wait_operation_id=%llu");
      ("timer stale guard", "stale timer wait operation");
      ("parked owner invariant", "parked without wait owner");
    ]
  in
  List.iter
    (fun (name, needle) ->
      Alcotest.(check bool) name true (contains_substring runtime needle))
    required

let test_channel_waiters_carry_operation_identity () =
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let required =
    [
      ("channel waiter record", "typedef struct blorp_ChannelFiberWaiter");
      ("channel waiter carries fiber", "blorp_Fiber* fiber;");
      ("channel waiter carries operation id", "uint64_t wait_operation_id;");
      ("channel waiter carries kind", "blorp_ChannelWaitKind kind;");
      ("channel waiter carries deadline", "uint64_t deadline_ns;");
      ("channel waiter carries wake reason", "blorp_ChannelWakeReason wake_reason;");
      ("channel send queue uses waiter records", "blorp_ChannelFiberWaiter* send_waiters_head;");
      ("channel recv queue uses waiter records", "blorp_ChannelFiberWaiter* recv_waiters_head;");
      ("channel waiter init helper", "__ch_fiber_waiter_init");
      ("channel waiter current helper", "__ch_fiber_waiter_current");
      ("channel stale wait guard", "stale channel wait operation");
    ]
  in
  List.iter
    (fun (name, needle) ->
      Alcotest.(check bool) name true (contains_substring runtime needle))
    required;
  Alcotest.(check bool)
    "channel send queue no longer stores raw fibers" false
    (contains_substring runtime "blorp_Fiber* send_waiters_head;");
  Alcotest.(check bool)
    "channel recv queue no longer stores raw fibers" false
    (contains_substring runtime "blorp_Fiber* recv_waiters_head;")

let test_cloexec_helpers_declare_fallback_locals_once () =
  let runtime =
    read_first_existing
      [ "compiler/lib/runtime.c"; "../lib/runtime.c"; "lib/runtime.c" ]
  in
  let forbidden =
    [
      "int fd = socket(domain, type | SOCK_CLOEXEC, protocol);";
      "int fd = socket(domain, type, protocol);";
      "int client_fd = accept4(fd, addr, addr_len, SOCK_CLOEXEC);";
      "int client_fd = accept(fd, addr, addr_len);";
    ]
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime helper has no branch-local redeclaration: " ^ needle)
        false
        (contains_substring runtime needle))
    forbidden;
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        ("runtime helper assigns shared local: " ^ needle)
        true
        (contains_substring runtime needle))
    [
      String.concat "\n"
        [ "int fd;"; "#if defined(SOCK_CLOEXEC)"; "    fd = socket" ];
      String.concat "\n"
        [
          "int client_fd;";
          "#if defined(__linux__) && defined(SOCK_CLOEXEC)";
          "    client_fd = accept4";
        ];
    ]

let test_float16_vector_read_decl_uses_feature_guard () =
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
  let helper = "static inline _Float16 blorp_vector_read_f16" in
  let scalar_op =
    "blorp_Vector* blorp_vector_scalar_op_float16(int op, blorp_Vector* v, \
     _Float16 scalar);"
  in
  Alcotest.(check bool)
    "runtime_decl exposes Float16 vector reader when _Float16 is supported" true
    (contains_substring runtime_decl ("#ifdef __FLT16_MAX__\n" ^ helper));
  Alcotest.(check bool)
    "runtime_decl Float16 vector reader is not clang-only" false
    (contains_substring runtime_decl ("#ifdef __clang__\n" ^ helper));
  Alcotest.(check bool)
    "runtime_decl exposes Float16 scalar vector ops when _Float16 is supported"
    true
    (contains_substring runtime_decl ("#ifdef __FLT16_MAX__\n" ^ scalar_op));
  Alcotest.(check bool)
    "runtime_decl Float16 scalar vector ops are not clang-only" false
    (contains_substring runtime_decl ("#ifdef __clang__\n" ^ scalar_op));
  Alcotest.(check bool)
    "runtime Float16 vector reader uses same feature guard" true
    (contains_substring runtime ("#ifdef __FLT16_MAX__\n" ^ helper))

let test_channel_status_runtime_abi_is_declared () =
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
  let try_signature =
    "long blorp_channel_try_recv_status_raw(blorp_Channel* ch, void** out)"
  in
  let timeout_signature =
    "long blorp_channel_recv_timeout_status_raw(blorp_Channel* ch, long \
     timeout_ms, void** out)"
  in
  Alcotest.(check bool)
    "runtime_decl exposes nonblocking receive status ABI" true
    (contains_substring runtime_decl (try_signature ^ ";"));
  Alcotest.(check bool)
    "runtime implements nonblocking receive status ABI" true
    (contains_substring runtime try_signature);
  Alcotest.(check bool)
    "runtime_decl exposes timed receive status ABI" true
    (contains_substring runtime_decl (timeout_signature ^ ";"));
  Alcotest.(check bool)
    "runtime implements timed receive status ABI" true
    (contains_substring runtime timeout_signature);
  List.iter
    (fun (name, value) ->
      let define = Printf.sprintf "#define %s %s" name value in
      Alcotest.(check bool)
        ("runtime_decl exposes channel status constant " ^ name)
        true
        (contains_substring runtime_decl define);
      Alcotest.(check bool)
        ("runtime uses channel status constant " ^ name)
        true
        (contains_substring runtime define))
    [
      ("BLORP_CHANNEL_SEND_ACCEPTED", "0L");
      ("BLORP_CHANNEL_SEND_WOULD_BLOCK", "1L");
      ("BLORP_CHANNEL_SEND_SEALED", "2L");
      ("BLORP_CHANNEL_SEND_TIMED_OUT", "3L");
      ("BLORP_CHANNEL_RECV_VALUE", "0L");
      ("BLORP_CHANNEL_RECV_WOULD_BLOCK", "1L");
      ("BLORP_CHANNEL_RECV_SEALED", "2L");
      ("BLORP_CHANNEL_RECV_TIMED_OUT", "3L");
    ]

let test_stream_element_layout_is_explicit () =
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
  List.iter
    (fun (label, source) ->
      Alcotest.(check bool)
        (label ^ " defines stream element layout enum")
        true
        (contains_substring source "typedef enum blorp_StreamElementLayout");
      Alcotest.(check bool)
        (label ^ " uses one stream element layout field")
        true
        (contains_substring source "blorp_StreamElementLayout elem_layout;");
      if
        contains_substring source "bool elem_is_rc;"
        || contains_substring source "bool elem_is_owned;"
        || contains_substring source "bool state_is_rc;"
      then
        Alcotest.failf
          "%s should represent stream element/state ownership with explicit \
           layout enums, not independent elem_is_rc/elem_is_owned/state_is_rc \
           booleans"
          label)
    [ ("runtime", runtime); ("runtime_decl", runtime_decl) ]

let parse_std_int_record_field line =
  match String.split_on_char ':' (String.trim line) with
  | [ name; ty ] ->
      let ty = String.trim ty in
      if ty = "Int" || ty = "Int," then Some (String.trim name) else None
  | _ -> None

let scheduler_stats_std_fields () =
  let source = read_std_file "instrumentation.brp" in
  let rec collect in_record fields = function
    | [] -> Alcotest.fail "Could not find complete SchedulerStats record in std"
    | line :: rest ->
        let trimmed = String.trim line in
        if trimmed = "record SchedulerStats {" then collect true fields rest
        else if in_record && trimmed = "}" then List.rev fields
        else if in_record then
          let fields =
            match parse_std_int_record_field line with
            | Some field -> field :: fields
            | None -> fields
          in
          collect true fields rest
        else collect false fields rest
  in
  collect false [] (split_lines source)

let parse_c_long_struct_field line =
  let line = String.trim line in
  if starts_with line "long " && ends_with line ";" then
    let without_long = String.sub line 5 (String.length line - 5) in
    Some (String.sub without_long 0 (String.length without_long - 1))
  else None

let find_index pred items =
  let rec loop i = function
    | [] -> None
    | x :: xs -> if pred x then Some i else loop (i + 1) xs
  in
  loop 0 items

let scheduler_stats_c_fields label source =
  let lines = split_lines source in
  let end_index =
    match
      find_index
        (fun line -> contains_substring line "} blorp_SchedulerStats;")
        lines
    with
    | Some i -> i
    | None -> Alcotest.failf "%s has no blorp_SchedulerStats typedef" label
  in
  let indexed = List.mapi (fun i line -> (i, line)) lines in
  let start_index =
    indexed
    |> List.filter (fun (i, line) ->
        i < end_index && String.trim line = "typedef struct {")
    |> List.rev
    |> function
    | (i, _) :: _ -> i
    | [] -> Alcotest.failf "%s has no SchedulerStats struct start" label
  in
  indexed
  |> List.filter_map (fun (i, line) ->
      if i > start_index && i < end_index then parse_c_long_struct_field line
      else None)

let test_scheduler_stats_layout_matches_std_record () =
  let expected = scheduler_stats_std_fields () in
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
  Alcotest.(check (list string))
    "runtime SchedulerStats field order" expected
    (scheduler_stats_c_fields "runtime.c" runtime);
  Alcotest.(check (list string))
    "runtime_decl SchedulerStats field order" expected
    (scheduler_stats_c_fields "runtime_decl.c" runtime_decl)

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

let test_string_append_str_uses_runtime_bulk_append () =
  let string_src = read_std_file "string.brp" in
  if not (contains_substring string_src "builtin(\"blorp_string_append\")") then
    Alcotest.fail
      "std/string.append_str should use the runtime bulk append helper"

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

let direct_runtime_option_returns_in_std () =
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
                            (Blorp.Ast.BuiltinRuntimeHelper symbol, _);
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
    direct_runtime_option_returns_in_std ()
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
          "list IR functions are not shadowed by codegen builtins" `Quick
          test_list_ir_functions_not_shadowed_by_codegen_builtins;
        Alcotest.test_case "builtin lookup uses exact module paths" `Quick
          test_builtin_lookup_uses_exact_module_paths;
        Alcotest.test_case "list IR HOFs have no runtime C ABI" `Quick
          test_list_ir_hofs_have_no_runtime_c_abi;
        Alcotest.test_case "fiber intrusive links are role-specific" `Quick
          test_fiber_intrusive_links_are_role_specific;
        Alcotest.test_case "scheduler debug observability has named hooks" `Quick
          test_scheduler_debug_observability_has_named_hooks;
        Alcotest.test_case "fiber lifecycle state is explicit" `Quick
          test_fiber_lifecycle_state_is_explicit;
        Alcotest.test_case "fiber wake cause is explicit" `Quick
          test_fiber_wake_cause_is_explicit;
        Alcotest.test_case "fiber wait owner is explicit" `Quick
          test_fiber_wait_owner_is_explicit;
        Alcotest.test_case "channel waiters carry operation identity" `Quick
          test_channel_waiters_carry_operation_identity;
        Alcotest.test_case "cloexec helpers declare fallback locals once" `Quick
          test_cloexec_helpers_declare_fallback_locals_once;
        Alcotest.test_case "Float16 vector reader ABI uses feature guard" `Quick
          test_float16_vector_read_decl_uses_feature_guard;
        Alcotest.test_case "channel status ABI is declared" `Quick
          test_channel_status_runtime_abi_is_declared;
        Alcotest.test_case "stream element layout is explicit" `Quick
          test_stream_element_layout_is_explicit;
        Alcotest.test_case "scheduler stats layout matches std record" `Quick
          test_scheduler_stats_layout_matches_std_record;
        Alcotest.test_case "std source dir initialized from config" `Quick
          test_std_source_dir_initialized_from_config;
        Alcotest.test_case "list join uses IR string_append" `Quick
          test_list_join_uses_ir_string_append;
        Alcotest.test_case "string append_str uses runtime bulk append" `Quick
          test_string_append_str_uses_runtime_bulk_append;
        Alcotest.test_case "builder module removed from std" `Quick
          test_builder_module_removed_from_std;
        Alcotest.test_case "public ABI types have std anchors" `Quick
          test_public_abi_types_have_std_anchors;
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
