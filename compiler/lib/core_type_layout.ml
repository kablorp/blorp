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
  | "List" | "ParallelList" | "Dict" | "Set" | "Tensor" | "Vector" | "Matrix"
  | "Builder" | "Slice" | "Option" | "Result" | "Task" | "Channel" | "Stream"
  | "FallibleStream" | "std/stream::FallibleStream"
  | "std_stream__FallibleStream" | "TcpListener" | "TcpStream"
  | "ConcurrencyError" ->
      Some managed_layout
  | "FileReader" | "FileWriter" | "File" | "std/file::FileReader"
  | "std/file::FileWriter" | "std/file::File" | "std_file__FileReader"
  | "std_file__FileWriter" | "std_file__File" ->
      Some unmanaged_layout
  | "Int" | "Bool" | "Char" | "Float" | "Float32" | "Float16" | "Int128"
  | "UInt128" | "Void" | "Ptr" | "Module" ->
      Some unmanaged_layout
  | name when List.mem name Types.all_int_type_names -> Some unmanaged_layout
  | _ -> None

let apply_alias_subst params args body =
  let subst = List.combine params args in
  List.fold_left
    (fun acc (param, arg) ->
      Codegen_types.apply_codegen_subst [ (param, arg) ] acc)
    body subst

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
            List.length params = List.length args
            && go (name :: seen) (apply_alias_subst params args target)
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
            List.length params = List.length args
            && is_option (name :: seen) (apply_alias_subst params args target)
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
                | None when Types.is_type_param_name name ->
                    Known managed_layout
                | None when meta.is_enum_name name -> Known unmanaged_layout
                | None when meta.is_value_record_name name ->
                    Known unmanaged_layout
                | None when meta.is_managed_name name -> Known managed_layout
                | None -> (
                    match meta.lookup_alias name with
                    | Some (params, target) when not (List.mem name seen) ->
                        if List.length params = List.length args then
                          go (name :: seen)
                            (apply_alias_subst params args target)
                        else
                          Invalid_value_type
                            (Printf.sprintf
                               "type alias %s expects %d argument(s), got %d"
                               name (List.length params) (List.length args))
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

let layout_or_error ?(phase = Core_error.Other "type_layout")
    ?(loc = Ast.dummy_loc) (meta : metadata) (ty : Ast.type_expr) :
    ownership_layout =
  match classify meta ty with
  | Known layout -> layout
  | Unknown_named name ->
      Core_error.errorf phase loc
        ~hint:
          "register the type as a record, value struct, enum, union, builtin \
           runtime type, or explicit unmanaged FFI type before ownership \
           analysis"
        "ownership classifier has no layout for type %s" name
  | Invalid_value_type msg ->
      Core_error.errorf phase loc
        ~hint:"only runtime value types may participate in ownership analysis"
        "%s" msg

let requires_release (layout : ownership_layout) =
  match layout.release with ArcRelease -> true | NoReleaseNeeded -> false

let requires_retain (layout : ownership_layout) =
  match layout.retain with ArcRetain -> true | NoRetainNeeded -> false

let classify_debug_heap_value (meta : metadata) (ty : Ast.type_expr) :
    debug_heap_classification =
  match classify meta ty with
  | Known { ownership = Managed; _ } -> DebugHeapValue
  | Known { ownership = Unmanaged; _ } -> DebugStackValue
  | Unknown_named name -> DebugHeapUnknownNamed name
  | Invalid_value_type msg -> DebugHeapInvalidValueType msg

let is_boxed_storage_release_free_value_type = function
  | Ast.TyNamed (("Float" | "Float32" | "Float16"), []) -> true
  | Ast.TyNamed (("Int" | "Bool" | "Char"), []) -> true
  | ty when Types.is_any_integer_type ty -> true
  | Ast.TyRange _ -> true
  | ty when Types.Dim.is_value_dim ty -> true
  | _ -> false

let is_arc_boxed_storage_value_type = function
  | Ast.TyNamed (("Int128" | "UInt128"), []) -> true
  | _ -> false

(** Release policy for values after erasure into generic boxed storage. This
    intentionally differs from source-value ownership: value records are
    unmanaged by value, but [blorp_box_struct] returns ARC-managed heap storage
    that container and variant destructors must release. Wide integer source
    values are unmanaged scalars, but their generic [void*] representation is
    also an ARC-managed heap box because 128-bit payloads do not fit in a
    pointer-sized immediate. *)
let boxed_storage_release_or_error ?(phase = Core_error.Other "type_layout")
    ?(loc = Ast.dummy_loc) (meta : metadata) (ty : Ast.type_expr) :
    release_capability =
  let rec go seen ty =
    match normalize_for_ownership ty with
    | ty when is_stack_option_type meta ty -> ArcRelease
    | ty when is_stack_result_type meta ty -> ArcRelease
    | ty when is_arc_boxed_storage_value_type ty -> ArcRelease
    | ty when is_boxed_storage_release_free_value_type ty -> NoReleaseNeeded
    | Ast.TyNamed (name, _) when meta.is_enum_name name -> NoReleaseNeeded
    | Ast.TyNamed (name, _) when meta.is_value_record_name name -> ArcRelease
    | Ast.TyNamed (name, args) -> (
        match meta.lookup_alias name with
        | Some (params, target) when not (List.mem name seen) ->
            if List.length params = List.length args then
              go (name :: seen) (apply_alias_subst params args target)
            else
              layout_or_error ~phase ~loc meta ty |> fun layout ->
              layout.release
        | Some _ ->
            layout_or_error ~phase ~loc meta ty |> fun layout -> layout.release
        | None ->
            layout_or_error ~phase ~loc meta ty |> fun layout -> layout.release)
    | ty -> layout_or_error ~phase ~loc meta ty |> fun layout -> layout.release
  in
  go [] ty

let requires_release_or_error ?(phase = Core_error.Other "type_layout")
    ?(loc = Ast.dummy_loc) (meta : metadata) (ty : Ast.type_expr) : bool =
  layout_or_error ~phase ~loc meta ty |> requires_release

let requires_retain_or_error ?(phase = Core_error.Other "type_layout")
    ?(loc = Ast.dummy_loc) (meta : metadata) (ty : Ast.type_expr) : bool =
  layout_or_error ~phase ~loc meta ty |> requires_retain

let boxed_storage_requires_release_or_error
    ?(phase = Core_error.Other "type_layout") ?(loc = Ast.dummy_loc)
    (meta : metadata) (ty : Ast.type_expr) : bool =
  match boxed_storage_release_or_error ~phase ~loc meta ty with
  | ArcRelease -> true
  | NoReleaseNeeded -> false
