open Blorp.Operation_result_metadata

let contains haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if needle_len = 0 then true
  else if needle_len > haystack_len then false
  else
    let rec loop i =
      if i + needle_len > haystack_len then false
      else if String.sub haystack i needle_len = needle then true
      else loop (i + 1)
    in
    loop 0

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let len = in_channel_length ic in
      really_input_string ic len)

let read_first_existing paths =
  match List.find_opt Sys.file_exists paths with
  | Some path -> read_file path
  | None ->
      Alcotest.failf "none of these files exist: %s" (String.concat ", " paths)

let find_project_file rel =
  let rec search dir remaining =
    let candidate = Filename.concat dir rel in
    if Sys.file_exists candidate then Some candidate
    else if remaining = 0 then None
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else search parent (remaining - 1)
  in
  match search (Sys.getcwd ()) 8 with
  | Some path -> path
  | None -> Alcotest.failf "project file not found from cwd: %s" rel

let runtime_decl_source () =
  read_first_existing
    [
      Filename.concat "lib" "runtime_decl.c";
      Filename.concat ".." (Filename.concat "lib" "runtime_decl.c");
      Filename.concat "compiler" (Filename.concat "lib" "runtime_decl.c");
      Filename.concat "compiler"
        (Filename.concat "_build"
           (Filename.concat "default" (Filename.concat "lib" "runtime_decl.c")));
    ]

let require_contains label content needle =
  Alcotest.(check bool) label true (contains content needle)

let std_source_path_for_module module_path = module_path ^ ".brp"

let std_source_decls path =
  let source = read_file (find_project_file path) in
  match
    Blorp.Modules.parse_source ~filename:path ~hoist_nested:false source
  with
  | Ok decls -> decls
  | Error err -> Alcotest.failf "failed to parse %s: %s" path err.message

let public_direct_builtin_exposures builtin_name decls =
  decls
  |> List.filter_map (fun (decl : Blorp.Ast.decl) ->
      match decl.decl_desc with
      | DFunc
          {
            func_name = Some func_name;
            func_body = FuncBuiltinBody (BuiltinRuntime runtime_name, _);
            _;
          }
        when runtime_name = builtin_name ->
          Some func_name
      | DFunc _ | DType _ | DTypeAlias _ | DRecord _ | DVar _ | DTrait _
      | DImpl _ | DImport _ | DPrivate _ ->
          None)

let assert_public_direct_std_builtin ~source_module ~builtin_name =
  let path = std_source_path_for_module (source_module_path source_module) in
  let decls = std_source_decls path in
  let public_exposures = public_direct_builtin_exposures builtin_name decls in
  match public_exposures with
  | _ :: _ -> ()
  | [] ->
      Alcotest.failf
        "%s should be exposed by a public std function as direct \
         builtin(\"%s\") in %s"
        builtin_name builtin_name path

let expected_dns_operations =
  [
    ( "blorp_dns_resolve_raw",
      "blorp_DnsAddressesResult",
      [ "List" ],
      1,
      Blorp.Env_types.ResourceResultOrdinary );
  ]

let expected_tcp_operations =
  [
    ( "blorp_tcp_listen_raw",
      "blorp_TcpListenerResult",
      [ "TcpListener" ],
      0,
      Blorp.Env_types.ResourceResultIndependent );
    ( "blorp_tcp_listen_numeric_raw",
      "blorp_TcpListenerResult",
      [ "TcpListener" ],
      0,
      Blorp.Env_types.ResourceResultIndependent );
    ( "blorp_tcp_accept_raw",
      "blorp_TcpStreamResult",
      [ "TcpStream" ],
      0,
      Blorp.Env_types.ResourceResultIndependent );
    ( "blorp_tcp_connect_raw",
      "blorp_TcpStreamResult",
      [ "TcpStream" ],
      0,
      Blorp.Env_types.ResourceResultIndependent );
    ( "blorp_tcp_connect_numeric_raw",
      "blorp_TcpStreamResult",
      [ "TcpStream" ],
      0,
      Blorp.Env_types.ResourceResultIndependent );
    ( "blorp_tcp_read_raw",
      "blorp_TcpBytesResult",
      [ "Bytes" ],
      1,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_tcp_write_raw",
      "blorp_TcpIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_tcp_write_all_raw",
      "blorp_TcpVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_tcp_set_reuse_addr_raw",
      "blorp_TcpVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_tcp_local_port_listener_raw",
      "blorp_TcpIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_tcp_local_port_stream_raw",
      "blorp_TcpIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_tcp_set_timeout_listener_raw",
      "blorp_TcpVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_tcp_set_timeout_stream_raw",
      "blorp_TcpVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
  ]

let expected_udp_operations =
  [
    ( "blorp_udp_socket_raw",
      "blorp_UdpSocketResult",
      [ "UdpSocket" ],
      0,
      Blorp.Env_types.ResourceResultIndependent );
    ( "blorp_udp_bind_raw",
      "blorp_UdpVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_udp_bind_numeric_raw",
      "blorp_UdpVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_udp_send_to_raw",
      "blorp_UdpIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_udp_send_to_numeric_raw",
      "blorp_UdpIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_udp_send_to_wait_raw",
      "blorp_UdpIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_udp_send_to_wait_numeric_raw",
      "blorp_UdpIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_udp_recv_from_raw",
      "blorp_UdpDatagramResult",
      [ "Datagram" ],
      1,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_udp_local_port_raw",
      "blorp_UdpIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
  ]

let expected_tls_operations =
  [
    ( "blorp_tls_connect_raw",
      "blorp_TlsSessionResult",
      [ "TlsSession" ],
      0,
      Blorp.Env_types.ResourceResultDependent );
    ( "blorp_tls_read_raw",
      "blorp_TlsBytesResult",
      [ "Bytes" ],
      1,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_tls_write_raw",
      "blorp_TlsIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_tls_write_all_raw",
      "blorp_TlsVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
  ]

let expected_websocket_operations =
  [
    ( "blorp_websocket_connect_raw",
      "blorp_WebSocketSessionResult",
      [ "WebSocketSession" ],
      0,
      Blorp.Env_types.ResourceResultIndependent );
    ( "blorp_websocket_receive_raw",
      "blorp_WebSocketMessageResult",
      [ "Message" ],
      1,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_websocket_send_text_raw",
      "blorp_WebSocketVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_websocket_send_binary_raw",
      "blorp_WebSocketVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_websocket_send_ping_raw",
      "blorp_WebSocketVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_websocket_send_pong_raw",
      "blorp_WebSocketVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_websocket_send_close_raw",
      "blorp_WebSocketVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
  ]

let expected_file_operations =
  [
    ( "blorp_file_open_read_raw",
      "blorp_FileOpenReaderResult",
      [ "FileReader" ],
      0,
      Blorp.Env_types.ResourceResultIndependent );
    ( "blorp_file_open_write_raw",
      "blorp_FileOpenWriterResult",
      [ "FileWriter" ],
      0,
      Blorp.Env_types.ResourceResultIndependent );
    ( "blorp_file_open_append_raw",
      "blorp_FileOpenWriterResult",
      [ "FileWriter" ],
      0,
      Blorp.Env_types.ResourceResultIndependent );
    ( "blorp_file_open_read_write_raw",
      "blorp_FileOpenResult",
      [ "File" ],
      0,
      Blorp.Env_types.ResourceResultIndependent );
    ( "blorp_file_read_text_reader_raw",
      "blorp_FileStringResult",
      [ "String" ],
      1,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_read_text_file_raw",
      "blorp_FileStringResult",
      [ "String" ],
      1,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_read_bytes_reader_raw",
      "blorp_FileBytesResult",
      [ "Bytes" ],
      1,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_read_bytes_file_raw",
      "blorp_FileBytesResult",
      [ "Bytes" ],
      1,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_read_chunk_reader_raw",
      "blorp_FileBytesResult",
      [ "Bytes" ],
      1,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_read_chunk_file_raw",
      "blorp_FileBytesResult",
      [ "Bytes" ],
      1,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_write_text_writer_raw",
      "blorp_FileVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_write_text_file_raw",
      "blorp_FileVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_write_bytes_writer_raw",
      "blorp_FileVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_write_bytes_file_raw",
      "blorp_FileVoidResult",
      [ "Void" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_write_chunk_writer_raw",
      "blorp_FileIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_write_chunk_file_raw",
      "blorp_FileIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_count_lines_reader_raw",
      "blorp_FileIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
    ( "blorp_file_count_lines_file_raw",
      "blorp_FileIntResult",
      [ "Int" ],
      0,
      Blorp.Env_types.ResourceResultOrdinary );
  ]

let expected_operations =
  expected_dns_operations @ expected_tcp_operations @ expected_tls_operations
  @ expected_udp_operations @ expected_websocket_operations
  @ expected_file_operations

let expected_operation_arguments =
  [
    ("blorp_dns_resolve_raw", [ ArgBorrow ]);
    ("blorp_tcp_listen_raw", [ ArgBorrow; ArgBorrow; ArgBorrow ]);
    ("blorp_tcp_listen_numeric_raw", [ ArgBorrow; ArgBorrow; ArgBorrow ]);
    ("blorp_tcp_accept_raw", [ ArgBorrow ]);
    ("blorp_tcp_connect_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_tcp_connect_numeric_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_tcp_read_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_tcp_write_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_tcp_write_all_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_tcp_set_reuse_addr_raw", [ ArgBorrow ]);
    ("blorp_tcp_local_port_listener_raw", [ ArgBorrow ]);
    ("blorp_tcp_local_port_stream_raw", [ ArgBorrow ]);
    ("blorp_tcp_set_timeout_listener_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_tcp_set_timeout_stream_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_tls_connect_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_tls_read_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_tls_write_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_tls_write_all_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_udp_socket_raw", []);
    ("blorp_udp_bind_raw", [ ArgBorrow; ArgBorrow; ArgBorrow ]);
    ("blorp_udp_bind_numeric_raw", [ ArgBorrow; ArgBorrow; ArgBorrow ]);
    ("blorp_udp_send_to_raw", [ ArgBorrow; ArgBorrow; ArgBorrow; ArgBorrow ]);
    ( "blorp_udp_send_to_numeric_raw",
      [ ArgBorrow; ArgBorrow; ArgBorrow; ArgBorrow ] );
    ( "blorp_udp_send_to_wait_raw",
      [ ArgBorrow; ArgBorrow; ArgBorrow; ArgBorrow ] );
    ( "blorp_udp_send_to_wait_numeric_raw",
      [ ArgBorrow; ArgBorrow; ArgBorrow; ArgBorrow ] );
    ("blorp_udp_recv_from_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_udp_local_port_raw", [ ArgBorrow ]);
    ("blorp_websocket_connect_raw", [ ArgBorrow ]);
    ("blorp_websocket_receive_raw", [ ArgBorrow ]);
    ("blorp_websocket_send_text_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_websocket_send_binary_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_websocket_send_ping_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_websocket_send_pong_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_websocket_send_close_raw", [ ArgBorrow; ArgBorrow; ArgBorrow ]);
    ("blorp_file_open_read_raw", [ ArgBorrow ]);
    ("blorp_file_open_write_raw", [ ArgBorrow ]);
    ("blorp_file_open_append_raw", [ ArgBorrow ]);
    ("blorp_file_open_read_write_raw", [ ArgBorrow ]);
    ("blorp_file_read_text_reader_raw", [ ArgBorrow ]);
    ("blorp_file_read_text_file_raw", [ ArgBorrow ]);
    ("blorp_file_read_bytes_reader_raw", [ ArgBorrow ]);
    ("blorp_file_read_bytes_file_raw", [ ArgBorrow ]);
    ("blorp_file_read_chunk_reader_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_file_read_chunk_file_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_file_write_text_writer_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_file_write_text_file_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_file_write_bytes_writer_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_file_write_bytes_file_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_file_write_chunk_writer_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_file_write_chunk_file_raw", [ ArgBorrow; ArgBorrow ]);
    ("blorp_file_count_lines_reader_raw", [ ArgBorrow ]);
    ("blorp_file_count_lines_file_raw", [ ArgBorrow ]);
  ]

let expected_boxed_only_operations =
  [
    "blorp_file_open_read_raw";
    "blorp_file_open_write_raw";
    "blorp_file_open_append_raw";
    "blorp_file_open_read_write_raw";
  ]

let expected_parking_operations =
  [
    "blorp_tcp_accept_raw";
    "blorp_tcp_connect_raw";
    "blorp_tcp_connect_numeric_raw";
    "blorp_tcp_read_raw";
    "blorp_tcp_write_raw";
    "blorp_tcp_write_all_raw";
    "blorp_tls_connect_raw";
    "blorp_tls_read_raw";
    "blorp_tls_write_raw";
    "blorp_tls_write_all_raw";
    "blorp_udp_send_to_wait_raw";
    "blorp_udp_send_to_wait_numeric_raw";
    "blorp_udp_recv_from_raw";
    "blorp_websocket_connect_raw";
    "blorp_websocket_receive_raw";
    "blorp_websocket_send_text_raw";
    "blorp_websocket_send_binary_raw";
    "blorp_websocket_send_ping_raw";
    "blorp_websocket_send_pong_raw";
    "blorp_websocket_send_close_raw";
  ]

let expected_os_worker_blocking_operations =
  [ ("blorp_dns_resolve_raw", "platform resolver") ]

let expected_fiber_ordinary_result_wait_operations =
  [
    "blorp_tcp_read_raw";
    "blorp_tcp_write_raw";
    "blorp_tcp_write_all_raw";
    "blorp_tls_read_raw";
    "blorp_tls_write_raw";
    "blorp_tls_write_all_raw";
    "blorp_udp_send_to_wait_raw";
    "blorp_udp_send_to_wait_numeric_raw";
    "blorp_udp_recv_from_raw";
    "blorp_websocket_receive_raw";
    "blorp_websocket_send_text_raw";
    "blorp_websocket_send_binary_raw";
    "blorp_websocket_send_ping_raw";
    "blorp_websocket_send_pong_raw";
    "blorp_websocket_send_close_raw";
  ]

let expected_fiber_resource_result_wait_operations =
  [
    ("blorp_tcp_accept_raw", "independent");
    ("blorp_tcp_connect_raw", "independent");
    ("blorp_tcp_connect_numeric_raw", "independent");
    ("blorp_tls_connect_raw", "dependent");
    ("blorp_websocket_connect_raw", "independent");
  ]

let expected_os_worker_result_wait_operations =
  [ ("blorp_dns_resolve_raw", "platform resolver", "ordinary") ]

let expected_fallible_stream_sources =
  [
    ( "blorp_file_chunks_reader_raw",
      "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_FILE",
      [ ArgBorrow ] );
    ( "blorp_file_chunks_with_size_reader_raw",
      "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_FILE",
      [ ArgBorrow; ArgBorrow ] );
    ( "blorp_file_lines_reader_raw",
      "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_FILE",
      [ ArgBorrow ] );
    ( "blorp_file_bytes_reader_raw",
      "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_FILE",
      [ ArgBorrow ] );
    ( "blorp_file_windows_reader_raw",
      "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_FILE",
      [ ArgBorrow; ArgBorrow ] );
    ( "blorp_udp_datagrams_raw",
      "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_UDP",
      [ ArgBorrow; ArgBorrow ] );
    ( "blorp_tcp_chunks_raw",
      "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_TCP",
      [ ArgBorrow; ArgBorrow ] );
    ( "blorp_tcp_lines_raw",
      "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_TCP",
      [ ArgBorrow ] );
    ( "blorp_tls_chunks_raw",
      "BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_TLS",
      [ ArgBorrow; ArgBorrow ] );
  ]

let expected_fallible_stream_terminals =
  [
    ( "blorp_fallible_stream_collect_raw",
      "blorp_FallibleStreamListResult",
      StreamPayloadList,
      [ ArgBorrow ],
      [] );
    ( "blorp_fallible_stream_fold_raw",
      "blorp_FallibleStreamValueResult",
      StreamPayloadErased,
      [ ArgBorrow; ArgConsume; ArgBorrow; ArgBorrow ],
      [ 1 ] );
    ( "blorp_fallible_stream_count_raw",
      "blorp_FallibleStreamIntResult",
      StreamPayloadInt,
      [ ArgBorrow ],
      [] );
  ]
  @ List.map
      (fun name ->
        ( name,
          "blorp_FallibleStreamValueResult",
          StreamPayloadOption,
          [ ArgBorrow; ArgBorrow ],
          [] ))
      fallible_stream_find_terminal_names
  @ [
      ( "blorp_fallible_stream_any_raw",
        "blorp_FallibleStreamBoolResult",
        StreamPayloadBool,
        [ ArgBorrow; ArgBorrow ],
        [] );
      ( "blorp_fallible_stream_all_raw",
        "blorp_FallibleStreamBoolResult",
        StreamPayloadBool,
        [ ArgBorrow; ArgBorrow ],
        [] );
    ]

let test_bridges_are_manifested () =
  let actual_names =
    List.map
      (fun (bridge : result_bridge) -> bridge.builtin_name)
      result_bridges
  in
  let expected_names =
    List.map (fun (name, _, _, _, _) -> name) expected_operations
  in
  Alcotest.(check (list string)) "bridge names" expected_names actual_names;
  List.iter
    (fun (name, result_c_type, type_name_hints, release_mask, result_policy) ->
      match find_result_bridge name with
      | None -> Alcotest.failf "missing result bridge for %s" name
      | Some bridge ->
          Alcotest.(check string)
            (name ^ " runtime result") result_c_type
            bridge.runtime_result_c_type;
          List.iter
            (fun type_name ->
              Alcotest.(check bool)
                (name ^ " accepts " ^ type_name)
                true
                (List.mem type_name (success_payload_type_names bridge.success)))
            type_name_hints;
          Alcotest.(check int)
            (name ^ " success release mask")
            release_mask bridge.success.release_mask;
          Alcotest.(check bool)
            (name ^ " resource result policy")
            true
            (bridge.success.resource_result_policy = result_policy))
    expected_operations

let test_operation_arguments_are_manifested () =
  Alcotest.(check (list string))
    "operation argument metadata names"
    (List.map fst expected_operation_arguments)
    (List.map
       (fun (bridge : result_bridge) -> bridge.builtin_name)
       result_bridges);
  List.iter
    (fun (name, arguments) ->
      match find_result_bridge name with
      | None -> Alcotest.failf "missing result bridge for %s" name
      | Some bridge ->
          Alcotest.(check bool)
            (name ^ " argument ownership")
            true
            (bridge.arguments = arguments))
    expected_operation_arguments

let test_result_layout_policy_is_manifested () =
  Alcotest.(check (list string))
    "boxed-only result bridge names" expected_boxed_only_operations
    (result_bridges
    |> List.filter_map (fun (bridge : result_bridge) ->
        match bridge.result_layout_policy with
        | BoxedResultOnly _ -> Some bridge.builtin_name
        | DefaultResultLayout -> None));
  List.iter
    (fun name ->
      match find_result_bridge name with
      | Some { result_layout_policy = BoxedResultOnly reason; _ } ->
          Alcotest.(check bool)
            (name ^ " boxed-only reason")
            true
            (String.length reason > 0)
      | Some _ -> Alcotest.failf "%s is not boxed-only" name
      | None -> Alcotest.failf "missing result bridge for %s" name)
    expected_boxed_only_operations

let test_tcp_error_mapping_is_explicit () =
  Alcotest.(check (list string))
    "tcp error tags"
    [
      "BLORP_TCP_ERROR_INVALID_INPUT";
      "BLORP_TCP_ERROR_TIMED_OUT";
      "BLORP_TCP_ERROR_CLOSED";
      "BLORP_TCP_ERROR_BUSY";
      "BLORP_TCP_ERROR_DNS";
      "BLORP_TCP_ERROR_CONNECTION_FAILED";
      "BLORP_TCP_ERROR_INTERRUPTED";
      "BLORP_TCP_ERROR_UNSUPPORTED";
      "BLORP_TCP_ERROR_OTHER";
    ]
    (List.map (fun case -> case.runtime_tag) tcp_error_mapping.cases);
  Alcotest.(check (list string))
    "tcp error constructors"
    [
      "InvalidInput";
      "TimedOut";
      "Closed";
      "Busy";
      "Dns";
      "ConnectionFailed";
      "Interrupted";
      "Unsupported";
      "Other";
    ]
    (List.map (fun case -> case.constructor_name) tcp_error_mapping.cases);
  Alcotest.(check string)
    "none tag" "BLORP_TCP_ERROR_NONE" tcp_error_mapping.none_tag;
  Alcotest.(check string) "detail field" "detail" tcp_error_mapping.detail_field

let test_dns_error_mapping_is_explicit () =
  Alcotest.(check (list string))
    "dns error tags"
    [ "BLORP_DNS_ERROR_INVALID_HOST"; "BLORP_DNS_ERROR_LOOKUP_FAILED" ]
    (List.map (fun case -> case.runtime_tag) dns_error_mapping.cases);
  Alcotest.(check (list string))
    "dns error constructors"
    [ "InvalidHost"; "LookupFailed" ]
    (List.map (fun case -> case.constructor_name) dns_error_mapping.cases);
  Alcotest.(check string)
    "none tag" "BLORP_DNS_ERROR_NONE" dns_error_mapping.none_tag;
  Alcotest.(check string) "detail field" "detail" dns_error_mapping.detail_field

let test_udp_error_mapping_is_explicit () =
  Alcotest.(check (list string))
    "udp error tags"
    [
      "BLORP_UDP_ERROR_INVALID_INPUT";
      "BLORP_UDP_ERROR_TIMED_OUT";
      "BLORP_UDP_ERROR_CLOSED";
      "BLORP_UDP_ERROR_BUSY";
      "BLORP_UDP_ERROR_DNS";
      "BLORP_UDP_ERROR_INTERRUPTED";
      "BLORP_UDP_ERROR_UNSUPPORTED";
      "BLORP_UDP_ERROR_OTHER";
    ]
    (List.map (fun case -> case.runtime_tag) udp_error_mapping.cases);
  Alcotest.(check (list string))
    "udp error constructors"
    [
      "InvalidInput";
      "TimedOut";
      "Closed";
      "Busy";
      "Dns";
      "Interrupted";
      "Unsupported";
      "Other";
    ]
    (List.map (fun case -> case.constructor_name) udp_error_mapping.cases);
  Alcotest.(check string)
    "none tag" "BLORP_UDP_ERROR_NONE" udp_error_mapping.none_tag;
  Alcotest.(check string) "detail field" "detail" udp_error_mapping.detail_field

let test_tls_error_mapping_is_explicit () =
  Alcotest.(check (list string))
    "tls error tags"
    [
      "BLORP_TLS_ERROR_INVALID_INPUT";
      "BLORP_TLS_ERROR_HANDSHAKE_FAILED";
      "BLORP_TLS_ERROR_TRANSPORT";
      "BLORP_TLS_ERROR_CERTIFICATE";
      "BLORP_TLS_ERROR_PROTOCOL";
      "BLORP_TLS_ERROR_TIMED_OUT";
      "BLORP_TLS_ERROR_CLOSED";
      "BLORP_TLS_ERROR_BUSY";
      "BLORP_TLS_ERROR_UNSUPPORTED";
      "BLORP_TLS_ERROR_OTHER";
    ]
    (List.map (fun case -> case.runtime_tag) tls_error_mapping.cases);
  Alcotest.(check (list string))
    "tls error constructors"
    [
      "InvalidInput";
      "HandshakeFailed";
      "Transport";
      "Certificate";
      "Protocol";
      "TimedOut";
      "Closed";
      "Busy";
      "Unsupported";
      "Other";
    ]
    (List.map (fun case -> case.constructor_name) tls_error_mapping.cases);
  Alcotest.(check string)
    "none tag" "BLORP_TLS_ERROR_NONE" tls_error_mapping.none_tag;
  Alcotest.(check string) "detail field" "detail" tls_error_mapping.detail_field

let test_websocket_error_mapping_is_explicit () =
  Alcotest.(check (list string))
    "websocket error tags"
    [
      "BLORP_WEBSOCKET_ERROR_INVALID_URL";
      "BLORP_WEBSOCKET_ERROR_HANDSHAKE_FAILED";
      "BLORP_WEBSOCKET_ERROR_TRANSPORT";
      "BLORP_WEBSOCKET_ERROR_TLS";
      "BLORP_WEBSOCKET_ERROR_PROTOCOL";
      "BLORP_WEBSOCKET_ERROR_TIMED_OUT";
      "BLORP_WEBSOCKET_ERROR_CLOSED";
      "BLORP_WEBSOCKET_ERROR_BUSY";
      "BLORP_WEBSOCKET_ERROR_UNSUPPORTED";
      "BLORP_WEBSOCKET_ERROR_OTHER";
    ]
    (List.map (fun case -> case.runtime_tag) websocket_error_mapping.cases);
  Alcotest.(check (list string))
    "websocket error constructors"
    [
      "InvalidUrl";
      "HandshakeFailed";
      "Transport";
      "Tls";
      "Protocol";
      "TimedOut";
      "Closed";
      "Busy";
      "Unsupported";
      "Other";
    ]
    (List.map (fun case -> case.constructor_name) websocket_error_mapping.cases);
  Alcotest.(check string)
    "none tag" "BLORP_WEBSOCKET_ERROR_NONE" websocket_error_mapping.none_tag;
  Alcotest.(check string)
    "detail field" "detail" websocket_error_mapping.detail_field

let test_file_error_mapping_is_explicit () =
  Alcotest.(check (list string))
    "file error tags"
    [
      "BLORP_FILE_ERROR_NOT_FOUND";
      "BLORP_FILE_ERROR_PERMISSION_DENIED";
      "BLORP_FILE_ERROR_ALREADY_EXISTS";
      "BLORP_FILE_ERROR_INVALID_INPUT";
      "BLORP_FILE_ERROR_INTERRUPTED";
      "BLORP_FILE_ERROR_TIMED_OUT";
      "BLORP_FILE_ERROR_UNSUPPORTED";
      "BLORP_FILE_ERROR_OTHER";
    ]
    (List.map (fun case -> case.runtime_tag) file_error_mapping.cases);
  Alcotest.(check (list string))
    "file error constructors"
    [
      "NotFound";
      "PermissionDenied";
      "AlreadyExists";
      "InvalidInput";
      "Interrupted";
      "TimedOut";
      "Unsupported";
      "Other";
    ]
    (List.map (fun case -> case.constructor_name) file_error_mapping.cases);
  Alcotest.(check string)
    "none tag" "BLORP_FILE_ERROR_NONE" file_error_mapping.none_tag;
  Alcotest.(check string)
    "detail field" "detail" file_error_mapping.detail_field

let test_independent_resource_results_are_explicit () =
  Alcotest.(check bool)
    "tcp accept produces an independent stream" true
    (resource_result_policy "blorp_tcp_accept_raw"
    = Some Blorp.Env_types.ResourceResultIndependent);
  Alcotest.(check bool)
    "tls connect produces a dependent session" false
    (resource_result_policy "blorp_tls_connect_raw"
    = Some Blorp.Env_types.ResourceResultIndependent)

let test_parking_metadata_is_explicit () =
  Alcotest.(check (list string))
    "parking operation-result bridges" expected_parking_operations
    (result_bridges
    |> List.filter_map (fun (bridge : result_bridge) ->
        if bridge_is_cancellation_point bridge then Some bridge.builtin_name
        else None));
  Alcotest.(check (list (pair string string)))
    "OS-worker-blocking operation-result bridges"
    expected_os_worker_blocking_operations
    (result_bridges
    |> List.filter_map (fun (bridge : result_bridge) ->
        match bridge.wait_behavior with
        | BlocksOsWorker reason -> Some (bridge.builtin_name, reason)
        | DoesNotWait | ParksFiber -> None));
  List.iter
    (fun (bridge : result_bridge) ->
      Alcotest.(check bool)
        (bridge.builtin_name ^ " is impure")
        true
        (Blorp.Builtin_metadata.is_impure bridge.builtin_name);
      Alcotest.(check bool)
        (bridge.builtin_name ^ " cancellation-point metadata")
        (bridge_is_cancellation_point bridge)
        (Blorp.Builtin_metadata.is_cancellation_point bridge.builtin_name);
      Alcotest.(check bool)
        (bridge.builtin_name ^ " OS-worker-blocking metadata")
        (bridge_blocks_os_worker bridge)
        (Blorp.Builtin_metadata.is_os_worker_blocking bridge.builtin_name))
    result_bridges

let resource_result_policy_name = function
  | Blorp.Env_types.ResourceResultOrdinary -> "ordinary"
  | Blorp.Env_types.ResourceResultIndependent -> "independent"
  | Blorp.Env_types.ResourceResultDependent -> "dependent"

let result_ownership_kind_name = function
  | OrdinaryResult -> "ordinary"
  | ResourceResult policy -> resource_result_policy_name policy

let test_operation_wait_class_is_explicit () =
  Alcotest.(check (list string))
    "fiber waits returning ordinary results"
    expected_fiber_ordinary_result_wait_operations
    (result_bridges
    |> List.filter_map (fun (bridge : result_bridge) ->
        match bridge_operation_wait_class bridge with
        | ParksFiberReturning OrdinaryResult -> Some bridge.builtin_name
        | DoesNotSuspend | BlocksOsWorkerReturning _
        | ParksFiberReturning (ResourceResult _) ->
            None));
  Alcotest.(check (list (pair string string)))
    "fiber waits returning resources"
    expected_fiber_resource_result_wait_operations
    (result_bridges
    |> List.filter_map (fun (bridge : result_bridge) ->
        match bridge_operation_wait_class bridge with
        | ParksFiberReturning (ResourceResult policy) ->
            Some (bridge.builtin_name, resource_result_policy_name policy)
        | DoesNotSuspend | BlocksOsWorkerReturning _
        | ParksFiberReturning OrdinaryResult ->
            None));
  Alcotest.(check (list (triple string string string)))
    "OS-worker-blocking result operations"
    expected_os_worker_result_wait_operations
    (result_bridges
    |> List.filter_map (fun (bridge : result_bridge) ->
        match bridge_operation_wait_class bridge with
        | BlocksOsWorkerReturning (reason, result_kind) ->
            Some
              ( bridge.builtin_name,
                reason,
                result_ownership_kind_name result_kind )
        | DoesNotSuspend | ParksFiberReturning _ -> None))

let test_fallible_stream_sources_are_manifested () =
  Alcotest.(check (list string))
    "stream source names"
    (List.map (fun (name, _, _) -> name) expected_fallible_stream_sources)
    (List.map
       (fun (source : fallible_stream_source) -> source.builtin_name)
       fallible_stream_sources);
  List.iter
    (fun (name, error_domain, arguments) ->
      match find_fallible_stream_source name with
      | None -> Alcotest.failf "missing fallible stream source %s" name
      | Some source ->
          Alcotest.(check string)
            (name ^ " return type") "blorp_FallibleStream*"
            source.runtime_return_c_type;
          Alcotest.(check string)
            (name ^ " error domain") error_domain source.error_domain;
          Alcotest.(check bool)
            (name ^ " arguments") true
            (source.arguments = arguments);
          Alcotest.(check bool)
            (name ^ " is impure") true
            (Blorp.Builtin_metadata.is_impure name);
          Alcotest.(check bool)
            (name ^ " constructor is not a cancellation point")
            false
            (Blorp.Builtin_metadata.is_cancellation_point name);
          Alcotest.(check bool)
            (name ^ " constructor does not block an OS worker")
            false
            (Blorp.Builtin_metadata.is_os_worker_blocking name))
    expected_fallible_stream_sources

let test_fallible_stream_terminals_are_manifested () =
  Alcotest.(check (list string))
    "stream terminal names"
    (List.map
       (fun (name, _, _, _, _) -> name)
       expected_fallible_stream_terminals)
    (List.map
       (fun (terminal : fallible_stream_terminal) -> terminal.builtin_name)
       fallible_stream_terminals);
  List.iter
    (fun (name, result_c_type, payload, arguments, void_boxed_args) ->
      match find_fallible_stream_terminal name with
      | None -> Alcotest.failf "missing fallible stream terminal %s" name
      | Some terminal ->
          Alcotest.(check string)
            (name ^ " runtime result") result_c_type
            terminal.runtime_result_c_type;
          Alcotest.(check bool)
            (name ^ " payload") true
            (terminal.payload = payload);
          Alcotest.(check bool)
            (name ^ " arguments") true
            (terminal.arguments = arguments);
          Alcotest.(check (list int))
            (name ^ " void boxed args")
            void_boxed_args terminal.void_boxed_args;
          Alcotest.(check bool)
            (name ^ " terminal cancellation-point metadata")
            true
            (terminal_is_cancellation_point terminal);
          Alcotest.(check bool)
            (name ^ " builtin cancellation-point metadata")
            true
            (Blorp.Builtin_metadata.is_cancellation_point name);
          Alcotest.(check bool)
            (name ^ " terminal does not block an OS worker")
            false
            (Blorp.Builtin_metadata.is_os_worker_blocking name))
    expected_fallible_stream_terminals

let duplicate_strings values =
  let sorted = List.sort String.compare values in
  let rec loop previous duplicates = function
    | [] -> List.rev duplicates
    | value :: rest ->
        let duplicates =
          match previous with
          | Some prev when prev = value ->
              if List.mem value duplicates then duplicates
              else value :: duplicates
          | _ -> duplicates
        in
        loop (Some value) duplicates rest
  in
  loop None [] sorted

let expect_no_duplicates label values =
  Alcotest.(check (list string)) label [] (duplicate_strings values)

let test_manifest_names_are_unique () =
  expect_no_duplicates "operation result bridge names"
    (List.map
       (fun (bridge : result_bridge) -> bridge.builtin_name)
       result_bridges);
  expect_no_duplicates "fallible stream source names"
    (List.map
       (fun (source : fallible_stream_source) -> source.builtin_name)
       fallible_stream_sources);
  expect_no_duplicates "fallible stream terminal names"
    (List.map
       (fun (terminal : fallible_stream_terminal) -> terminal.builtin_name)
       fallible_stream_terminals);
  List.iter
    (fun (label, mapping) ->
      expect_no_duplicates (label ^ " runtime tags")
        (List.map (fun case -> case.runtime_tag) mapping.cases);
      expect_no_duplicates (label ^ " constructors")
        (List.map (fun case -> case.constructor_name) mapping.cases);
      expect_no_duplicates
        (label ^ " accepted type names")
        mapping.accepted_type_names)
    [
      ("tcp errors", tcp_error_mapping);
      ("udp errors", udp_error_mapping);
      ("tls errors", tls_error_mapping);
      ("websocket errors", websocket_error_mapping);
      ("file errors", file_error_mapping);
      ("dns errors", dns_error_mapping);
    ]

let test_manifest_matches_runtime_declarations () =
  let declarations = runtime_decl_source () in
  List.iter
    (fun (bridge : result_bridge) ->
      require_contains
        (bridge.builtin_name ^ " result type declared")
        declarations bridge.runtime_result_c_type;
      require_contains
        (bridge.builtin_name ^ " declaration uses manifest result")
        declarations
        (bridge.runtime_result_c_type ^ " " ^ bridge.runtime_c_name ^ "("))
    result_bridges;
  require_contains "dns none tag declared" declarations
    dns_error_mapping.none_tag;
  List.iter
    (fun case ->
      require_contains
        ("dns error tag declared: " ^ case.runtime_tag)
        declarations case.runtime_tag)
    dns_error_mapping.cases;
  require_contains "tcp none tag declared" declarations
    tcp_error_mapping.none_tag;
  List.iter
    (fun case ->
      require_contains
        ("tcp error tag declared: " ^ case.runtime_tag)
        declarations case.runtime_tag)
    tcp_error_mapping.cases;
  require_contains "udp none tag declared" declarations
    udp_error_mapping.none_tag;
  List.iter
    (fun case ->
      require_contains
        ("udp error tag declared: " ^ case.runtime_tag)
        declarations case.runtime_tag)
    udp_error_mapping.cases;
  require_contains "tls none tag declared" declarations
    tls_error_mapping.none_tag;
  List.iter
    (fun case ->
      require_contains
        ("tls error tag declared: " ^ case.runtime_tag)
        declarations case.runtime_tag)
    tls_error_mapping.cases;
  require_contains "websocket none tag declared" declarations
    websocket_error_mapping.none_tag;
  List.iter
    (fun case ->
      require_contains
        ("websocket error tag declared: " ^ case.runtime_tag)
        declarations case.runtime_tag)
    websocket_error_mapping.cases;
  require_contains "file none tag declared" declarations
    file_error_mapping.none_tag;
  List.iter
    (fun case ->
      require_contains
        ("file error tag declared: " ^ case.runtime_tag)
        declarations case.runtime_tag)
    file_error_mapping.cases;
  List.iter
    (fun (source : fallible_stream_source) ->
      require_contains
        (source.builtin_name ^ " stream source declaration")
        declarations
        (source.runtime_return_c_type ^ " " ^ source.runtime_c_name ^ "(");
      require_contains
        (source.builtin_name ^ " stream source error domain")
        declarations source.error_domain)
    fallible_stream_sources;
  List.iter
    (fun (terminal : fallible_stream_terminal) ->
      require_contains
        (terminal.builtin_name ^ " stream terminal result declared")
        declarations terminal.runtime_result_c_type;
      require_contains
        (terminal.builtin_name ^ " stream terminal declaration")
        declarations
        (terminal.runtime_result_c_type ^ " " ^ terminal.runtime_c_name ^ "("))
    fallible_stream_terminals

let test_std_operation_result_builtins_are_public_direct () =
  List.iter
    (fun (bridge : result_bridge) ->
      assert_public_direct_std_builtin ~source_module:bridge.source_module
        ~builtin_name:bridge.builtin_name)
    result_bridges

let test_std_fallible_stream_sources_are_public_direct () =
  List.iter
    (fun (source : fallible_stream_source) ->
      assert_public_direct_std_builtin ~source_module:source.source_module
        ~builtin_name:source.builtin_name)
    fallible_stream_sources

let suite =
  [
    ( "operation_result_metadata",
      [
        Alcotest.test_case "bridges_are_manifested" `Quick
          test_bridges_are_manifested;
        Alcotest.test_case "operation_arguments_are_manifested" `Quick
          test_operation_arguments_are_manifested;
        Alcotest.test_case "result_layout_policy_is_manifested" `Quick
          test_result_layout_policy_is_manifested;
        Alcotest.test_case "dns_error_mapping_is_explicit" `Quick
          test_dns_error_mapping_is_explicit;
        Alcotest.test_case "tcp_error_mapping_is_explicit" `Quick
          test_tcp_error_mapping_is_explicit;
        Alcotest.test_case "udp_error_mapping_is_explicit" `Quick
          test_udp_error_mapping_is_explicit;
        Alcotest.test_case "tls_error_mapping_is_explicit" `Quick
          test_tls_error_mapping_is_explicit;
        Alcotest.test_case "websocket_error_mapping_is_explicit" `Quick
          test_websocket_error_mapping_is_explicit;
        Alcotest.test_case "file_error_mapping_is_explicit" `Quick
          test_file_error_mapping_is_explicit;
        Alcotest.test_case "independent_resource_results_are_explicit" `Quick
          test_independent_resource_results_are_explicit;
        Alcotest.test_case "parking_metadata_is_explicit" `Quick
          test_parking_metadata_is_explicit;
        Alcotest.test_case "operation_wait_class_is_explicit" `Quick
          test_operation_wait_class_is_explicit;
        Alcotest.test_case "fallible_stream_sources_are_manifested" `Quick
          test_fallible_stream_sources_are_manifested;
        Alcotest.test_case "fallible_stream_terminals_are_manifested" `Quick
          test_fallible_stream_terminals_are_manifested;
        Alcotest.test_case "manifest_names_are_unique" `Quick
          test_manifest_names_are_unique;
        Alcotest.test_case "manifest_matches_runtime_declarations" `Quick
          test_manifest_matches_runtime_declarations;
        Alcotest.test_case "std_operation_result_builtins_are_public_direct"
          `Quick test_std_operation_result_builtins_are_public_direct;
        Alcotest.test_case "std_fallible_stream_sources_are_public_direct"
          `Quick test_std_fallible_stream_sources_are_public_direct;
      ] );
  ]
