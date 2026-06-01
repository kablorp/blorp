(** Metadata for runtime operations that return native result structs.

    Codegen uses this table to bridge runtime-specific result structs into
    Blorp [Result] values. Keeping the operation shape here prevents each
    resource-backed subsystem from growing an ad hoc emitter branch. *)

type accepted_type_shape = NamedType of string list * accepted_type_shape list

type runtime_union_arg =
  | RuntimeOwnedField of string
  | RuntimeIntField of string

type runtime_union_case = {
  runtime_tag : string;
  constructor_name : string;
  args : runtime_union_arg list;
}

type runtime_success_payload =
  | RuntimeNoPayload
  | RuntimeField of string
  | RuntimeRecordFields of string list
  | RuntimeUnion of {
      runtime_tag_field : string;
      cases : runtime_union_case list;
    }

type success_payload = {
  accepted_type : accepted_type_shape;
  runtime_payload : runtime_success_payload;
  release_mask : int;
  resource_result_policy : Env_types.resource_result_policy;
}

type error_case = { runtime_tag : string; constructor_name : string }

type error_mapping = {
  accepted_type_names : string list;
  none_tag : string;
  detail_field : string;
  other_constructor : string;
  cases : error_case list;
}

type argument_ownership =
  | ArgBorrow
  | ArgRetain
  | ArgConsume
  | ArgCowConsume
  | ArgTransfer

type result_layout_policy = DefaultResultLayout | BoxedResultOnly of string

type runtime_wait_behavior =
  | DoesNotWait
  | ParksFiber
  | BlocksOsWorker of string

type result_ownership_kind =
  | OrdinaryResult
  | ResourceResult of Env_types.resource_result_policy

type operation_wait_class =
  | DoesNotSuspend
  | ParksFiberReturning of result_ownership_kind
  | BlocksOsWorkerReturning of string * result_ownership_kind

type source_module =
  | StdDns
  | StdTcp
  | StdTls
  | StdUdp
  | StdWebSocket
  | StdFile

let source_module_path = function
  | StdDns -> Codegen_names.mod_dns
  | StdTcp -> Codegen_names.mod_tcp
  | StdTls -> Codegen_names.mod_tls
  | StdUdp -> Codegen_names.mod_udp
  | StdWebSocket -> Codegen_names.mod_websocket
  | StdFile -> Codegen_names.mod_file

type result_bridge = {
  builtin_name : string;
  source_module : source_module;
  runtime_c_name : string;
  runtime_result_c_type : string;
  temp_prefix : string;
  wait_behavior : runtime_wait_behavior;
  arguments : argument_ownership list;
  result_layout_policy : result_layout_policy;
  success : success_payload;
  error : error_mapping;
}

type fallible_stream_source = {
  builtin_name : string;
  source_module : source_module;
  runtime_c_name : string;
  runtime_return_c_type : string;
  error_domain : string;
  arguments : argument_ownership list;
}

type fallible_stream_terminal_payload =
  | StreamPayloadList
  | StreamPayloadErased
  | StreamPayloadInt
  | StreamPayloadOption
  | StreamPayloadBool

type fallible_stream_terminal = {
  builtin_name : string;
  runtime_c_name : string;
  runtime_result_c_type : string;
  wait_behavior : runtime_wait_behavior;
  payload : fallible_stream_terminal_payload;
  arguments : argument_ownership list;
  void_boxed_args : int list;
}

let named_type names = NamedType (names, [])
let simple_type name = named_type [ name ]
let list_type elem = NamedType ([ "List" ], [ elem ])

let rec accepted_type_shape_to_string = function
  | NamedType (names, []) -> String.concat "|" names
  | NamedType (names, args) ->
      Printf.sprintf "%s[%s]" (String.concat "|" names)
        (String.concat ", " (List.map accepted_type_shape_to_string args))

let success_payload_type_names payload =
  match payload.accepted_type with NamedType (names, _) -> names

let rec accepted_type_shape_matches shape ty =
  match (shape, ty) with
  | NamedType (names, expected_args), Ast.TyNamed (name, actual_args) ->
      List.mem name names
      && List.length expected_args = List.length actual_args
      && List.for_all2 accepted_type_shape_matches expected_args actual_args
  | _ -> false

let success_payload_accepts_type payload ty =
  accepted_type_shape_matches payload.accepted_type ty

let success_payload_expected_type payload =
  accepted_type_shape_to_string payload.accepted_type

let tcp_error_mapping =
  {
    accepted_type_names =
      [ "TcpError"; "std/net/tcp::TcpError"; "std_net_tcp__TcpError" ];
    none_tag = "BLORP_TCP_ERROR_NONE";
    detail_field = "detail";
    other_constructor = "Other";
    cases =
      [
        {
          runtime_tag = "BLORP_TCP_ERROR_INVALID_INPUT";
          constructor_name = "InvalidInput";
        };
        {
          runtime_tag = "BLORP_TCP_ERROR_TIMED_OUT";
          constructor_name = "TimedOut";
        };
        { runtime_tag = "BLORP_TCP_ERROR_CLOSED"; constructor_name = "Closed" };
        { runtime_tag = "BLORP_TCP_ERROR_BUSY"; constructor_name = "Busy" };
        { runtime_tag = "BLORP_TCP_ERROR_DNS"; constructor_name = "Dns" };
        {
          runtime_tag = "BLORP_TCP_ERROR_CONNECTION_FAILED";
          constructor_name = "ConnectionFailed";
        };
        {
          runtime_tag = "BLORP_TCP_ERROR_INTERRUPTED";
          constructor_name = "Interrupted";
        };
        {
          runtime_tag = "BLORP_TCP_ERROR_UNSUPPORTED";
          constructor_name = "Unsupported";
        };
        { runtime_tag = "BLORP_TCP_ERROR_OTHER"; constructor_name = "Other" };
      ];
  }

let udp_error_mapping =
  {
    accepted_type_names =
      [ "UdpError"; "std/net/udp::UdpError"; "std_net_udp__UdpError" ];
    none_tag = "BLORP_UDP_ERROR_NONE";
    detail_field = "detail";
    other_constructor = "Other";
    cases =
      [
        {
          runtime_tag = "BLORP_UDP_ERROR_INVALID_INPUT";
          constructor_name = "InvalidInput";
        };
        {
          runtime_tag = "BLORP_UDP_ERROR_TIMED_OUT";
          constructor_name = "TimedOut";
        };
        { runtime_tag = "BLORP_UDP_ERROR_CLOSED"; constructor_name = "Closed" };
        { runtime_tag = "BLORP_UDP_ERROR_BUSY"; constructor_name = "Busy" };
        { runtime_tag = "BLORP_UDP_ERROR_DNS"; constructor_name = "Dns" };
        {
          runtime_tag = "BLORP_UDP_ERROR_INTERRUPTED";
          constructor_name = "Interrupted";
        };
        {
          runtime_tag = "BLORP_UDP_ERROR_UNSUPPORTED";
          constructor_name = "Unsupported";
        };
        { runtime_tag = "BLORP_UDP_ERROR_OTHER"; constructor_name = "Other" };
      ];
  }

let tls_error_mapping =
  {
    accepted_type_names =
      [ "TlsError"; "std/net/tls::TlsError"; "std_net_tls__TlsError" ];
    none_tag = "BLORP_TLS_ERROR_NONE";
    detail_field = "detail";
    other_constructor = "Other";
    cases =
      [
        {
          runtime_tag = "BLORP_TLS_ERROR_INVALID_INPUT";
          constructor_name = "InvalidInput";
        };
        {
          runtime_tag = "BLORP_TLS_ERROR_HANDSHAKE_FAILED";
          constructor_name = "HandshakeFailed";
        };
        {
          runtime_tag = "BLORP_TLS_ERROR_TRANSPORT";
          constructor_name = "Transport";
        };
        {
          runtime_tag = "BLORP_TLS_ERROR_CERTIFICATE";
          constructor_name = "Certificate";
        };
        {
          runtime_tag = "BLORP_TLS_ERROR_PROTOCOL";
          constructor_name = "Protocol";
        };
        {
          runtime_tag = "BLORP_TLS_ERROR_TIMED_OUT";
          constructor_name = "TimedOut";
        };
        { runtime_tag = "BLORP_TLS_ERROR_CLOSED"; constructor_name = "Closed" };
        { runtime_tag = "BLORP_TLS_ERROR_BUSY"; constructor_name = "Busy" };
        {
          runtime_tag = "BLORP_TLS_ERROR_UNSUPPORTED";
          constructor_name = "Unsupported";
        };
        { runtime_tag = "BLORP_TLS_ERROR_OTHER"; constructor_name = "Other" };
      ];
  }

let websocket_error_mapping =
  {
    accepted_type_names =
      [
        "WebSocketError";
        "std/net/websocket::WebSocketError";
        "std_net_websocket__WebSocketError";
      ];
    none_tag = "BLORP_WEBSOCKET_ERROR_NONE";
    detail_field = "detail";
    other_constructor = "Other";
    cases =
      [
        {
          runtime_tag = "BLORP_WEBSOCKET_ERROR_INVALID_URL";
          constructor_name = "InvalidUrl";
        };
        {
          runtime_tag = "BLORP_WEBSOCKET_ERROR_HANDSHAKE_FAILED";
          constructor_name = "HandshakeFailed";
        };
        {
          runtime_tag = "BLORP_WEBSOCKET_ERROR_TRANSPORT";
          constructor_name = "Transport";
        };
        { runtime_tag = "BLORP_WEBSOCKET_ERROR_TLS"; constructor_name = "Tls" };
        {
          runtime_tag = "BLORP_WEBSOCKET_ERROR_PROTOCOL";
          constructor_name = "Protocol";
        };
        {
          runtime_tag = "BLORP_WEBSOCKET_ERROR_TIMED_OUT";
          constructor_name = "TimedOut";
        };
        {
          runtime_tag = "BLORP_WEBSOCKET_ERROR_CLOSED";
          constructor_name = "Closed";
        };
        {
          runtime_tag = "BLORP_WEBSOCKET_ERROR_BUSY";
          constructor_name = "Busy";
        };
        {
          runtime_tag = "BLORP_WEBSOCKET_ERROR_UNSUPPORTED";
          constructor_name = "Unsupported";
        };
        {
          runtime_tag = "BLORP_WEBSOCKET_ERROR_OTHER";
          constructor_name = "Other";
        };
      ];
  }

let file_error_mapping =
  {
    accepted_type_names =
      [ "IOError"; "std/file::IOError"; "std_file__IOError" ];
    none_tag = "BLORP_FILE_ERROR_NONE";
    detail_field = "detail";
    other_constructor = "Other";
    cases =
      [
        {
          runtime_tag = "BLORP_FILE_ERROR_NOT_FOUND";
          constructor_name = "NotFound";
        };
        {
          runtime_tag = "BLORP_FILE_ERROR_PERMISSION_DENIED";
          constructor_name = "PermissionDenied";
        };
        {
          runtime_tag = "BLORP_FILE_ERROR_ALREADY_EXISTS";
          constructor_name = "AlreadyExists";
        };
        {
          runtime_tag = "BLORP_FILE_ERROR_INVALID_INPUT";
          constructor_name = "InvalidInput";
        };
        {
          runtime_tag = "BLORP_FILE_ERROR_INTERRUPTED";
          constructor_name = "Interrupted";
        };
        {
          runtime_tag = "BLORP_FILE_ERROR_TIMED_OUT";
          constructor_name = "TimedOut";
        };
        {
          runtime_tag = "BLORP_FILE_ERROR_UNSUPPORTED";
          constructor_name = "Unsupported";
        };
        { runtime_tag = "BLORP_FILE_ERROR_OTHER"; constructor_name = "Other" };
      ];
  }

let dns_error_mapping =
  {
    accepted_type_names =
      [ "DnsError"; "std/net/dns::DnsError"; "std_net_dns__DnsError" ];
    none_tag = "BLORP_DNS_ERROR_NONE";
    detail_field = "detail";
    other_constructor = "LookupFailed";
    cases =
      [
        {
          runtime_tag = "BLORP_DNS_ERROR_INVALID_HOST";
          constructor_name = "InvalidHost";
        };
        {
          runtime_tag = "BLORP_DNS_ERROR_LOOKUP_FAILED";
          constructor_name = "LookupFailed";
        };
      ];
  }

let resource_payload ~resource_result_policy names =
  {
    accepted_type = named_type names;
    runtime_payload = RuntimeField "handle";
    release_mask = 0;
    resource_result_policy;
  }

let value_payload ?(release_mask = 0) name =
  {
    accepted_type = simple_type name;
    runtime_payload = RuntimeField "value";
    release_mask;
    resource_result_policy = Env_types.ResourceResultOrdinary;
  }

let void_payload =
  {
    accepted_type = simple_type "Void";
    runtime_payload = RuntimeNoPayload;
    release_mask = 0;
    resource_result_policy = Env_types.ResourceResultOrdinary;
  }

let tcp_listener_payload =
  resource_payload ~resource_result_policy:Env_types.ResourceResultIndependent
    [ "TcpListener"; "std/net/tcp::TcpListener"; "std_net_tcp__TcpListener" ]

let tcp_stream_payload =
  resource_payload ~resource_result_policy:Env_types.ResourceResultIndependent
    [ "TcpStream"; "std/net/tcp::TcpStream"; "std_net_tcp__TcpStream" ]

let udp_socket_payload =
  resource_payload ~resource_result_policy:Env_types.ResourceResultIndependent
    [ "UdpSocket"; "std/net/udp::UdpSocket"; "std_net_udp__UdpSocket" ]

let file_reader_payload =
  resource_payload ~resource_result_policy:Env_types.ResourceResultIndependent
    [ "FileReader"; "std/file::FileReader"; "std_file__FileReader" ]

let file_writer_payload =
  resource_payload ~resource_result_policy:Env_types.ResourceResultIndependent
    [ "FileWriter"; "std/file::FileWriter"; "std_file__FileWriter" ]

let file_payload =
  resource_payload ~resource_result_policy:Env_types.ResourceResultIndependent
    [ "File"; "std/file::File"; "std_file__File" ]

let tls_session_payload =
  resource_payload ~resource_result_policy:Env_types.ResourceResultDependent
    [ "TlsSession"; "std/net/tls::TlsSession"; "std_net_tls__TlsSession" ]

let websocket_session_payload =
  resource_payload ~resource_result_policy:Env_types.ResourceResultIndependent
    [
      "WebSocketSession";
      "std/net/websocket::WebSocketSession";
      "std_net_websocket__WebSocketSession";
    ]

let websocket_message_payload =
  {
    accepted_type =
      named_type
        [
          "Message"; "std/net/websocket::Message"; "std_net_websocket__Message";
        ];
    runtime_payload =
      RuntimeUnion
        {
          runtime_tag_field = "message_kind";
          cases =
            [
              {
                runtime_tag = "BLORP_WEBSOCKET_MESSAGE_TEXT";
                constructor_name = "Text";
                args = [ RuntimeOwnedField "text" ];
              };
              {
                runtime_tag = "BLORP_WEBSOCKET_MESSAGE_BINARY";
                constructor_name = "Binary";
                args = [ RuntimeOwnedField "bytes" ];
              };
              {
                runtime_tag = "BLORP_WEBSOCKET_MESSAGE_CLOSE";
                constructor_name = "Close";
                args = [ RuntimeIntField "code"; RuntimeOwnedField "reason" ];
              };
              {
                runtime_tag = "BLORP_WEBSOCKET_MESSAGE_PING";
                constructor_name = "Ping";
                args = [ RuntimeOwnedField "bytes" ];
              };
              {
                runtime_tag = "BLORP_WEBSOCKET_MESSAGE_PONG";
                constructor_name = "Pong";
                args = [ RuntimeOwnedField "bytes" ];
              };
            ];
        };
    release_mask = 1;
    resource_result_policy = Env_types.ResourceResultOrdinary;
  }

let udp_datagram_payload =
  {
    accepted_type =
      named_type
        [ "Datagram"; "std/net/udp::Datagram"; "std_net_udp__Datagram" ];
    runtime_payload = RuntimeRecordFields [ "data"; "host"; "port" ];
    release_mask = 1;
    resource_result_policy = Env_types.ResourceResultOrdinary;
  }

let dns_addresses_payload =
  {
    accepted_type = list_type (simple_type "String");
    runtime_payload = RuntimeField "value";
    release_mask = 1;
    resource_result_policy = Env_types.ResourceResultOrdinary;
  }

let wait_behavior_is_cancellation_point = function
  | ParksFiber -> true
  | DoesNotWait | BlocksOsWorker _ -> false

let wait_behavior_blocks_os_worker = function
  | BlocksOsWorker _ -> true
  | DoesNotWait | ParksFiber -> false

let result_ownership_kind_of_policy = function
  | Env_types.ResourceResultOrdinary -> OrdinaryResult
  | Env_types.ResourceResultIndependent as policy -> ResourceResult policy
  | Env_types.ResourceResultDependent as policy -> ResourceResult policy

let bridge_result_ownership_kind (bridge : result_bridge) =
  result_ownership_kind_of_policy bridge.success.resource_result_policy

let bridge_operation_wait_class (bridge : result_bridge) =
  match bridge.wait_behavior with
  | DoesNotWait -> DoesNotSuspend
  | ParksFiber -> ParksFiberReturning (bridge_result_ownership_kind bridge)
  | BlocksOsWorker reason ->
      BlocksOsWorkerReturning (reason, bridge_result_ownership_kind bridge)

let bridge_is_cancellation_point (bridge : result_bridge) =
  wait_behavior_is_cancellation_point bridge.wait_behavior

let bridge_blocks_os_worker (bridge : result_bridge) =
  wait_behavior_blocks_os_worker bridge.wait_behavior

let terminal_is_cancellation_point (terminal : fallible_stream_terminal) =
  wait_behavior_is_cancellation_point terminal.wait_behavior

let terminal_blocks_os_worker (terminal : fallible_stream_terminal) =
  wait_behavior_blocks_os_worker terminal.wait_behavior

let tcp_bridge ?(wait_behavior = DoesNotWait) builtin_name runtime_result_c_type
    success arguments =
  {
    builtin_name;
    source_module = StdTcp;
    runtime_c_name = builtin_name;
    runtime_result_c_type;
    temp_prefix = "tcp";
    wait_behavior;
    arguments;
    result_layout_policy = DefaultResultLayout;
    success;
    error = tcp_error_mapping;
  }

let udp_bridge ?(wait_behavior = DoesNotWait) builtin_name runtime_result_c_type
    success arguments =
  {
    builtin_name;
    source_module = StdUdp;
    runtime_c_name = builtin_name;
    runtime_result_c_type;
    temp_prefix = "udp";
    wait_behavior;
    arguments;
    result_layout_policy = DefaultResultLayout;
    success;
    error = udp_error_mapping;
  }

let tls_bridge ?(wait_behavior = DoesNotWait) builtin_name runtime_result_c_type
    success arguments =
  {
    builtin_name;
    source_module = StdTls;
    runtime_c_name = builtin_name;
    runtime_result_c_type;
    temp_prefix = "tls";
    wait_behavior;
    arguments;
    result_layout_policy = DefaultResultLayout;
    success;
    error = tls_error_mapping;
  }

let websocket_bridge ?(wait_behavior = DoesNotWait) builtin_name
    runtime_result_c_type success arguments =
  {
    builtin_name;
    source_module = StdWebSocket;
    runtime_c_name = builtin_name;
    runtime_result_c_type;
    temp_prefix = "websocket";
    wait_behavior;
    arguments;
    result_layout_policy = DefaultResultLayout;
    success;
    error = websocket_error_mapping;
  }

let file_operation_bridge builtin_name runtime_result_c_type success arguments =
  {
    builtin_name;
    source_module = StdFile;
    runtime_c_name = builtin_name;
    runtime_result_c_type;
    temp_prefix = "file";
    wait_behavior = DoesNotWait;
    arguments;
    result_layout_policy = DefaultResultLayout;
    success;
    error = file_error_mapping;
  }

let dns_bridge builtin_name runtime_result_c_type success arguments =
  {
    builtin_name;
    source_module = StdDns;
    runtime_c_name = builtin_name;
    runtime_result_c_type;
    temp_prefix = "dns";
    wait_behavior = BlocksOsWorker "platform resolver";
    arguments;
    result_layout_policy = DefaultResultLayout;
    success;
    error = dns_error_mapping;
  }

let file_open_bridge builtin_name runtime_result_c_type success =
  {
    builtin_name;
    source_module = StdFile;
    runtime_c_name = builtin_name;
    runtime_result_c_type;
    temp_prefix = "file_open";
    wait_behavior = DoesNotWait;
    arguments = [ ArgBorrow ];
    result_layout_policy =
      BoxedResultOnly
        "typed file resource opens currently use the boxed Result ABI";
    success;
    error = file_error_mapping;
  }

let fallible_stream_source source_module
    ?(runtime_return_c_type = "blorp_FallibleStream*") builtin_name
    ~error_domain arguments =
  {
    builtin_name;
    source_module;
    runtime_c_name = builtin_name;
    runtime_return_c_type;
    error_domain;
    arguments;
  }

let fallible_stream_terminal ?(void_boxed_args = []) ~wait_behavior builtin_name
    runtime_result_c_type payload arguments =
  {
    builtin_name;
    runtime_c_name = builtin_name;
    runtime_result_c_type;
    wait_behavior;
    payload;
    arguments;
    void_boxed_args;
  }

let result_bridges =
  [
    dns_bridge "blorp_dns_resolve_raw" "blorp_DnsAddressesResult"
      dns_addresses_payload [ ArgBorrow ];
    tcp_bridge "blorp_tcp_listen_raw" "blorp_TcpListenerResult"
      tcp_listener_payload
      [ ArgBorrow; ArgBorrow; ArgBorrow ];
    tcp_bridge "blorp_tcp_listen_numeric_raw" "blorp_TcpListenerResult"
      tcp_listener_payload
      [ ArgBorrow; ArgBorrow; ArgBorrow ];
    tcp_bridge ~wait_behavior:ParksFiber "blorp_tcp_accept_raw"
      "blorp_TcpStreamResult" tcp_stream_payload [ ArgBorrow ];
    tcp_bridge ~wait_behavior:ParksFiber "blorp_tcp_connect_raw"
      "blorp_TcpStreamResult" tcp_stream_payload [ ArgBorrow; ArgBorrow ];
    tcp_bridge ~wait_behavior:ParksFiber "blorp_tcp_connect_numeric_raw"
      "blorp_TcpStreamResult" tcp_stream_payload [ ArgBorrow; ArgBorrow ];
    tcp_bridge ~wait_behavior:ParksFiber "blorp_tcp_read_raw"
      "blorp_TcpBytesResult"
      (value_payload ~release_mask:1 "Bytes")
      [ ArgBorrow; ArgBorrow ];
    tcp_bridge ~wait_behavior:ParksFiber "blorp_tcp_write_raw"
      "blorp_TcpIntResult" (value_payload "Int") [ ArgBorrow; ArgBorrow ];
    tcp_bridge ~wait_behavior:ParksFiber "blorp_tcp_write_all_raw"
      "blorp_TcpVoidResult" void_payload [ ArgBorrow; ArgBorrow ];
    tcp_bridge "blorp_tcp_set_reuse_addr_raw" "blorp_TcpVoidResult" void_payload
      [ ArgBorrow ];
    tcp_bridge "blorp_tcp_local_port_listener_raw" "blorp_TcpIntResult"
      (value_payload "Int") [ ArgBorrow ];
    tcp_bridge "blorp_tcp_local_port_stream_raw" "blorp_TcpIntResult"
      (value_payload "Int") [ ArgBorrow ];
    tcp_bridge "blorp_tcp_set_timeout_listener_raw" "blorp_TcpVoidResult"
      void_payload [ ArgBorrow; ArgBorrow ];
    tcp_bridge "blorp_tcp_set_timeout_stream_raw" "blorp_TcpVoidResult"
      void_payload [ ArgBorrow; ArgBorrow ];
    tls_bridge ~wait_behavior:ParksFiber "blorp_tls_connect_raw"
      "blorp_TlsSessionResult" tls_session_payload [ ArgBorrow; ArgBorrow ];
    tls_bridge ~wait_behavior:ParksFiber "blorp_tls_read_raw"
      "blorp_TlsBytesResult"
      (value_payload ~release_mask:1 "Bytes")
      [ ArgBorrow; ArgBorrow ];
    tls_bridge ~wait_behavior:ParksFiber "blorp_tls_write_raw"
      "blorp_TlsIntResult" (value_payload "Int") [ ArgBorrow; ArgBorrow ];
    tls_bridge ~wait_behavior:ParksFiber "blorp_tls_write_all_raw"
      "blorp_TlsVoidResult" void_payload [ ArgBorrow; ArgBorrow ];
    udp_bridge "blorp_udp_socket_raw" "blorp_UdpSocketResult" udp_socket_payload
      [];
    udp_bridge "blorp_udp_bind_raw" "blorp_UdpVoidResult" void_payload
      [ ArgBorrow; ArgBorrow; ArgBorrow ];
    udp_bridge "blorp_udp_bind_numeric_raw" "blorp_UdpVoidResult" void_payload
      [ ArgBorrow; ArgBorrow; ArgBorrow ];
    udp_bridge "blorp_udp_send_to_raw" "blorp_UdpIntResult"
      (value_payload "Int")
      [ ArgBorrow; ArgBorrow; ArgBorrow; ArgBorrow ];
    udp_bridge "blorp_udp_send_to_numeric_raw" "blorp_UdpIntResult"
      (value_payload "Int")
      [ ArgBorrow; ArgBorrow; ArgBorrow; ArgBorrow ];
    udp_bridge ~wait_behavior:ParksFiber "blorp_udp_send_to_wait_raw"
      "blorp_UdpIntResult" (value_payload "Int")
      [ ArgBorrow; ArgBorrow; ArgBorrow; ArgBorrow ];
    udp_bridge ~wait_behavior:ParksFiber "blorp_udp_send_to_wait_numeric_raw"
      "blorp_UdpIntResult" (value_payload "Int")
      [ ArgBorrow; ArgBorrow; ArgBorrow; ArgBorrow ];
    udp_bridge ~wait_behavior:ParksFiber "blorp_udp_recv_from_raw"
      "blorp_UdpDatagramResult" udp_datagram_payload [ ArgBorrow; ArgBorrow ];
    udp_bridge "blorp_udp_local_port_raw" "blorp_UdpIntResult"
      (value_payload "Int") [ ArgBorrow ];
    websocket_bridge ~wait_behavior:ParksFiber "blorp_websocket_connect_raw"
      "blorp_WebSocketSessionResult" websocket_session_payload [ ArgBorrow ];
    websocket_bridge ~wait_behavior:ParksFiber "blorp_websocket_receive_raw"
      "blorp_WebSocketMessageResult" websocket_message_payload [ ArgBorrow ];
    websocket_bridge ~wait_behavior:ParksFiber "blorp_websocket_send_text_raw"
      "blorp_WebSocketVoidResult" void_payload [ ArgBorrow; ArgBorrow ];
    websocket_bridge ~wait_behavior:ParksFiber "blorp_websocket_send_binary_raw"
      "blorp_WebSocketVoidResult" void_payload [ ArgBorrow; ArgBorrow ];
    websocket_bridge ~wait_behavior:ParksFiber "blorp_websocket_send_ping_raw"
      "blorp_WebSocketVoidResult" void_payload [ ArgBorrow; ArgBorrow ];
    websocket_bridge ~wait_behavior:ParksFiber "blorp_websocket_send_pong_raw"
      "blorp_WebSocketVoidResult" void_payload [ ArgBorrow; ArgBorrow ];
    websocket_bridge ~wait_behavior:ParksFiber "blorp_websocket_send_close_raw"
      "blorp_WebSocketVoidResult" void_payload
      [ ArgBorrow; ArgBorrow; ArgBorrow ];
    file_open_bridge "blorp_file_open_read_raw" "blorp_FileOpenReaderResult"
      file_reader_payload;
    file_open_bridge "blorp_file_open_write_raw" "blorp_FileOpenWriterResult"
      file_writer_payload;
    file_open_bridge "blorp_file_open_append_raw" "blorp_FileOpenWriterResult"
      file_writer_payload;
    file_open_bridge "blorp_file_open_read_write_raw" "blorp_FileOpenResult"
      file_payload;
    file_operation_bridge "blorp_file_read_text_reader_raw"
      "blorp_FileStringResult"
      (value_payload ~release_mask:1 "String")
      [ ArgBorrow ];
    file_operation_bridge "blorp_file_read_text_file_raw"
      "blorp_FileStringResult"
      (value_payload ~release_mask:1 "String")
      [ ArgBorrow ];
    file_operation_bridge "blorp_file_read_bytes_reader_raw"
      "blorp_FileBytesResult"
      (value_payload ~release_mask:1 "Bytes")
      [ ArgBorrow ];
    file_operation_bridge "blorp_file_read_bytes_file_raw"
      "blorp_FileBytesResult"
      (value_payload ~release_mask:1 "Bytes")
      [ ArgBorrow ];
    file_operation_bridge "blorp_file_read_chunk_reader_raw"
      "blorp_FileBytesResult"
      (value_payload ~release_mask:1 "Bytes")
      [ ArgBorrow; ArgBorrow ];
    file_operation_bridge "blorp_file_read_chunk_file_raw"
      "blorp_FileBytesResult"
      (value_payload ~release_mask:1 "Bytes")
      [ ArgBorrow; ArgBorrow ];
    file_operation_bridge "blorp_file_write_text_writer_raw"
      "blorp_FileVoidResult" void_payload [ ArgBorrow; ArgBorrow ];
    file_operation_bridge "blorp_file_write_text_file_raw"
      "blorp_FileVoidResult" void_payload [ ArgBorrow; ArgBorrow ];
    file_operation_bridge "blorp_file_write_bytes_writer_raw"
      "blorp_FileVoidResult" void_payload [ ArgBorrow; ArgBorrow ];
    file_operation_bridge "blorp_file_write_bytes_file_raw"
      "blorp_FileVoidResult" void_payload [ ArgBorrow; ArgBorrow ];
    file_operation_bridge "blorp_file_write_chunk_writer_raw"
      "blorp_FileIntResult" (value_payload "Int") [ ArgBorrow; ArgBorrow ];
    file_operation_bridge "blorp_file_write_chunk_file_raw"
      "blorp_FileIntResult" (value_payload "Int") [ ArgBorrow; ArgBorrow ];
    file_operation_bridge "blorp_file_count_lines_reader_raw"
      "blorp_FileIntResult" (value_payload "Int") [ ArgBorrow ];
    file_operation_bridge "blorp_file_count_lines_file_raw"
      "blorp_FileIntResult" (value_payload "Int") [ ArgBorrow ];
  ]

let find_result_bridge builtin_name =
  List.find_opt
    (fun (bridge : result_bridge) -> bridge.builtin_name = builtin_name)
    result_bridges

let fallible_stream_sources =
  [
    fallible_stream_source StdFile "blorp_file_chunks_reader_raw"
      ~error_domain:"BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_FILE" [ ArgBorrow ];
    fallible_stream_source StdFile "blorp_file_chunks_with_size_reader_raw"
      ~error_domain:"BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_FILE"
      [ ArgBorrow; ArgBorrow ];
    fallible_stream_source StdFile "blorp_file_lines_reader_raw"
      ~error_domain:"BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_FILE" [ ArgBorrow ];
    fallible_stream_source StdFile "blorp_file_bytes_reader_raw"
      ~error_domain:"BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_FILE" [ ArgBorrow ];
    fallible_stream_source StdFile "blorp_file_windows_reader_raw"
      ~error_domain:"BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_FILE"
      [ ArgBorrow; ArgBorrow ];
    fallible_stream_source StdUdp "blorp_udp_datagrams_raw"
      ~error_domain:"BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_UDP"
      [ ArgBorrow; ArgBorrow ];
    fallible_stream_source StdTcp "blorp_tcp_chunks_raw"
      ~error_domain:"BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_TCP"
      [ ArgBorrow; ArgBorrow ];
    fallible_stream_source StdTcp "blorp_tcp_lines_raw"
      ~error_domain:"BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_TCP" [ ArgBorrow ];
    fallible_stream_source StdTls "blorp_tls_chunks_raw"
      ~error_domain:"BLORP_FALLIBLE_STREAM_ERROR_DOMAIN_TLS"
      [ ArgBorrow; ArgBorrow ];
  ]

let find_fallible_stream_source builtin_name =
  List.find_opt
    (fun (source : fallible_stream_source) ->
      source.builtin_name = builtin_name)
    fallible_stream_sources

let fallible_stream_find_terminal_names =
  [
    "blorp_fallible_stream_find_raw";
    "blorp_fallible_stream_find_raw_nullable";
    "blorp_fallible_stream_find_raw_int";
    "blorp_fallible_stream_find_raw_int8";
    "blorp_fallible_stream_find_raw_int16";
    "blorp_fallible_stream_find_raw_int32";
    "blorp_fallible_stream_find_raw_int64";
    "blorp_fallible_stream_find_raw_uint8";
    "blorp_fallible_stream_find_raw_uint16";
    "blorp_fallible_stream_find_raw_uint32";
    "blorp_fallible_stream_find_raw_uint64";
    "blorp_fallible_stream_find_raw_float";
    "blorp_fallible_stream_find_raw_bool";
    "blorp_fallible_stream_find_raw_char";
    "blorp_fallible_stream_find_raw_f32";
    "blorp_fallible_stream_find_raw_f16";
  ]

let fallible_stream_terminals =
  [
    fallible_stream_terminal ~wait_behavior:ParksFiber
      "blorp_fallible_stream_collect_raw" "blorp_FallibleStreamListResult"
      StreamPayloadList [ ArgBorrow ];
    fallible_stream_terminal ~void_boxed_args:[ 1 ] ~wait_behavior:ParksFiber
      "blorp_fallible_stream_fold_raw" "blorp_FallibleStreamValueResult"
      StreamPayloadErased
      [ ArgBorrow; ArgConsume; ArgBorrow; ArgBorrow ];
    fallible_stream_terminal ~wait_behavior:ParksFiber
      "blorp_fallible_stream_count_raw" "blorp_FallibleStreamIntResult"
      StreamPayloadInt [ ArgBorrow ];
  ]
  @ List.map
      (fun name ->
        fallible_stream_terminal ~wait_behavior:ParksFiber name
          "blorp_FallibleStreamValueResult" StreamPayloadOption
          [ ArgBorrow; ArgBorrow ])
      fallible_stream_find_terminal_names
  @ [
      fallible_stream_terminal ~wait_behavior:ParksFiber
        "blorp_fallible_stream_any_raw" "blorp_FallibleStreamBoolResult"
        StreamPayloadBool [ ArgBorrow; ArgBorrow ];
      fallible_stream_terminal ~wait_behavior:ParksFiber
        "blorp_fallible_stream_all_raw" "blorp_FallibleStreamBoolResult"
        StreamPayloadBool [ ArgBorrow; ArgBorrow ];
    ]

let find_fallible_stream_terminal builtin_name =
  List.find_opt
    (fun (terminal : fallible_stream_terminal) ->
      terminal.builtin_name = builtin_name)
    fallible_stream_terminals

let resource_result_policy builtin_name =
  find_result_bridge builtin_name
  |> Option.map (fun bridge -> bridge.success.resource_result_policy)
