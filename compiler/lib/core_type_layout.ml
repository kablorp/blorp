(** Shared Core type-layout and ownership classification.

    Perceus and the C emitter both need to answer the same question:
    "does this value have a valid release path?"
    Historically they carried separate allow-lists with opposite fallbacks.
    This module is the single decision point so a missed custom type is a
    compiler invariant violation rather than silently unmanaged in one pass
    and conservatively managed in another.

    [ArcRetain] / [ArcRelease] mean [blorp_retain] / [blorp_release] are
    valid for the value. [ArcRelease] does not imply that the C object header
    needs a non-null nested-field destructor: heap records with only primitive
    fields still require ARC release, but their destructor callback may
    correctly be [NULL]. *)

type ownership = Managed | Unmanaged
type retain_capability = NoRetainNeeded | ArcRetain
type release_capability = NoReleaseNeeded | ArcRelease

type ownership_layout = {
  ownership : ownership;
  retain : retain_capability;
  release : release_capability;
}

type classification =
  | Known of ownership_layout
  | Unknown_named of string
  | Invalid_value_type of string

type debug_heap_classification =
  | DebugHeapValue
  | DebugStackValue
  | DebugHeapUnknownNamed of string
  | DebugHeapInvalidValueType of string

type metadata = {
  is_managed_name : string -> bool;
  is_value_record_name : string -> bool;
  is_enum_name : string -> bool;
  lookup_alias : string -> (string list * Ast.type_expr) option;
}

let metadata ?(is_managed_name = fun _ -> false)
    ?(is_value_record_name = fun _ -> false) ?(is_enum_name = fun _ -> false)
    ?(lookup_alias = fun _ -> None) () =
  { is_managed_name; is_value_record_name; is_enum_name; lookup_alias }

let metadata_for_registry (reg : Codegen_types.registry) =
  metadata
    ~is_managed_name:(Codegen_types.is_managed_type reg)
    ~is_value_record_name:(fun name -> Hashtbl.mem reg.value_records name)
    ~is_enum_name:(fun name -> Hashtbl.mem reg.enum_types name)
    ~lookup_alias:(fun name -> Hashtbl.find_opt reg.type_aliases name)
    ()

let layout_for_ownership = function
  | Managed -> { ownership = Managed; retain = ArcRetain; release = ArcRelease }
  | Unmanaged ->
      {
        ownership = Unmanaged;
        retain = NoRetainNeeded;
        release = NoReleaseNeeded;
      }

let managed_layout = layout_for_ownership Managed
let unmanaged_layout = layout_for_ownership Unmanaged

let builtin_layout = function
  | "String" | "Bytes" | "Fixed" | "StringSlice" | "MemStats" | "SchedulerStats"
  | "List" | "ParallelList" | "ParallelVector" | "ParallelMatrix" | "Dict"
  | "Set" | "Tensor" | "Vector" | "Matrix" | "Builder" | "Slice" | "Option"
  | "Result" | "Task" | "Channel" | "TcpListener" | "TcpStream" | "TlsSession"
  | "IpAddress" | "DnsName" | "InterfaceScope" | "std/net/tls::TlsSession"
  | "std_net_tls__TlsSession" | "WebSocketSession"
  | "std/net/websocket::WebSocketSession"
  | "std_net_websocket__WebSocketSession" | "ConcurrencyError"
  | "DirectoryEntry" | "std/fs::DirectoryEntry" | "std_fs__DirectoryEntry" ->
      Some managed_layout
  | name
    when Type_name_metadata.is_one_shot_stream_name name
         || Type_name_metadata.is_resource_source_name name ->
      Some managed_layout
  | "FileReader" | "FileWriter" | "FileAppender" | "FileReadWriter"
  | "FileReadAppender" | "std/fs::FileReader" | "std/fs::FileWriter"
  | "std/fs::FileAppender" | "std/fs::FileReadWriter"
  | "std/fs::FileReadAppender" | "std_fs__FileReader" | "std_fs__FileWriter"
  | "std_fs__FileAppender" | "std_fs__FileReadWriter"
  | "std_fs__FileReadAppender" | "Directory" | "std/fs::Directory"
  | "std_fs__Directory" | "UdpSocket" | "std/net/udp::UdpSocket"
  | "std_net_udp__UdpSocket" ->
      Some unmanaged_layout
  | "Int" | "Bool" | "Char" | "Float" | "Float32" | "Float16" | "Int128"
  | "UInt128" | "Void" | "Ptr" | "Module" | "Port" ->
      Some unmanaged_layout
  | name when List.mem name Types.all_int_type_names -> Some unmanaged_layout
  | _ -> None

let apply_alias_subst params args body =
  let subst = List.combine params args in
  List.fold_left
    (fun acc (param, arg) ->
      Codegen_types.apply_codegen_subst [ (param, arg) ] acc)
    body subst

let apply_alias_if_arity_matches params args target =
  if List.length params = List.length args then
    Some (apply_alias_subst params args target)
  else None

let option_exists pred = function Some value -> pred value | None -> false

let normalize_for_ownership ty =
  Types.map_type_expr
    (function
      | Ast.TyNamed (("Vector" | "Matrix"), args) ->
          Some (Ast.TyNamed ("Tensor", args))
      | Ast.TyNamed ("LiteralString", []) -> Some (Ast.TyNamed ("String", []))
      | _ -> None)
    ty

let is_runtime_stack_option_payload_name = function
  | "Void" | "Int" | "Int8" | "Int16" | "Int32" | "Int64" | "UInt8" | "UInt16"
  | "UInt32" | "UInt64" | "Float" | "Bool" | "Char" | "Float32" | "Float16" ->
      true
  | _ -> false

let is_stack_option_payload_type (meta : metadata) (ty : Ast.type_expr) : bool =
  let rec go seen ty =
    match normalize_for_ownership ty with
    | Ast.TyNamed (name, []) when is_runtime_stack_option_payload_name name ->
        true
    | Ast.TyNamed (("Int128" | "UInt128"), []) -> true
    | Ast.TyNamed (name, []) when meta.is_enum_name name -> true
    | Ast.TyNamed (name, []) when meta.is_value_record_name name -> true
    | Ast.TyNamed (name, args) -> (
        match meta.lookup_alias name with
        | Some (params, target) when not (List.mem name seen) ->
            apply_alias_if_arity_matches params args target
            |> option_exists (go (name :: seen))
        | Some _ | None -> false)
    | Ast.TyRange _ -> true
    | _ -> false
  in
  go [] ty

let is_stack_option_type (meta : metadata) (ty : Ast.type_expr) : bool =
  let rec is_option seen ty =
    match normalize_for_ownership ty with
    | Ast.TyNamed ("Option", [ payload_ty ]) ->
        is_stack_option_payload_type meta payload_ty
    | Ast.TyNamed (name, args) -> (
        match meta.lookup_alias name with
        | Some (params, target) when not (List.mem name seen) ->
            apply_alias_if_arity_matches params args target
            |> option_exists (is_option (name :: seen))
        | Some _ | None -> false)
    | _ -> false
  in
  is_option [] ty

let result_layout_metadata (meta : metadata) =
  Core_result_layout.metadata ~is_enum_name:meta.is_enum_name
    ~is_managed_name:meta.is_managed_name
    ~is_value_record_name:meta.is_value_record_name
    ~lookup_alias:meta.lookup_alias ()

let stack_result_layout (meta : metadata) (ty : Ast.type_expr) :
    Core_result_layout.layout option =
  match Core_result_layout.classify (result_layout_metadata meta) ty with
  | Core_result_layout.Known layout -> Some layout
  | Core_result_layout.BoxedUnion _ | Core_result_layout.Unknown_named _
  | Core_result_layout.Invalid_result_type _ ->
      None

let is_stack_result_type (meta : metadata) (ty : Ast.type_expr) : bool =
  stack_result_layout meta ty <> None

let classify (meta : metadata) (ty : Ast.type_expr) : classification =
  let rec go seen ty =
    match normalize_for_ownership ty with
    | Ast.TyArray _ -> Known managed_layout
    | ty when is_stack_option_type meta ty -> Known unmanaged_layout
    | ty -> (
        match stack_result_layout meta ty with
        | Some Core_result_layout.StackErased -> Known unmanaged_layout
        | Some Core_result_layout.StackManaged -> Known managed_layout
        | None -> (
            match ty with
            | Ast.TyNamed (name, args) -> (
                match builtin_layout name with
                | Some layout -> Known layout
                | None when meta.is_enum_name name -> Known unmanaged_layout
                | None when meta.is_value_record_name name ->
                    Known unmanaged_layout
                | None when meta.is_managed_name name -> Known managed_layout
                | None -> (
                    match meta.lookup_alias name with
                    | Some (params, target) when not (List.mem name seen) ->
                        apply_alias_if_arity_matches params args target
                        |> Option.fold
                             ~none:
                               (Invalid_value_type
                                  (Printf.sprintf
                                     "type alias %s expects %d argument(s), \
                                      got %d"
                                     name (List.length params)
                                     (List.length args)))
                             ~some:(go (name :: seen))
                    | Some _ ->
                        Invalid_value_type
                          (Printf.sprintf
                             "recursive type alias %s in ownership classifier"
                             name)
                    | None -> Unknown_named name))
            | Ast.TyFunc _ -> Known managed_layout
            | Ast.TyTuple _ -> Known managed_layout
            | Ast.TyArray _ -> Known managed_layout
            | Ast.TyVar name when Types.Dim.is_var_name name ->
                Known unmanaged_layout
            | Ast.TyVar _ | Ast.TyBoundVar _ | Ast.TySelf ->
                Known managed_layout
            | Ast.TyRange _ -> Known unmanaged_layout
            | Ast.TyConstInt _ | Ast.TyDimOp _ -> Known unmanaged_layout
            | Ast.TyVarDims _ ->
                Invalid_value_type
                  "variadic dimension pack reached ownership classifier in \
                   value position"
            | Ast.TyMeta _ ->
                Invalid_value_type "TyMeta reached ownership classifier"))
  in
  go [] ty

let classify_debug_heap_value (meta : metadata) (ty : Ast.type_expr) :
    debug_heap_classification =
  match classify meta ty with
  | Known { ownership = Managed; _ } -> DebugHeapValue
  | Known { ownership = Unmanaged; _ } -> DebugStackValue
  | Unknown_named name -> DebugHeapUnknownNamed name
  | Invalid_value_type msg -> DebugHeapInvalidValueType msg
