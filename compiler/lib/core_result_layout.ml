(** Representation policy for [Result[T, E]].

    [StackErased] stores both payloads in pointer-sized erased slots and never
    needs nested ARC work. [StackManaged] uses the same C struct, but carries a
    release mask so retain/drop can duplicate or release the active payload. *)

type layout = StackErased | StackManaged

type boxed_reason =
  | ManagedPayload of string
  | UnsupportedPayload of string
  | GenericPayload

type classification =
  | Known of layout
  | BoxedUnion of boxed_reason
  | Unknown_named of string
  | Invalid_result_type of string

type metadata = {
  is_enum_name : string -> bool;
  is_managed_name : string -> bool;
  is_value_record_name : string -> bool;
  lookup_alias : string -> (string list * Ast.type_expr) option;
}

let metadata ?(is_enum_name = fun _ -> false)
    ?(is_managed_name = fun _ -> false) ?(is_value_record_name = fun _ -> false)
    ?(lookup_alias = fun _ -> None) () =
  { is_enum_name; is_managed_name; is_value_record_name; lookup_alias }

let string_of_type = Types.type_to_string

let rec contains_generic_type = function
  | Ast.TyVar name -> not (Types.Dim.is_var_name name)
  | Ast.TyBoundVar _ -> true
  | Ast.TySelf | Ast.TyVarDims _ | Ast.TyMeta _ -> true
  | Ast.TyNamed (name, args) ->
      Types.is_type_param_name name || List.exists contains_generic_type args
  | Ast.TyArray (elem, dims) ->
      contains_generic_type elem || List.exists contains_generic_type dims
  | Ast.TyTuple elems -> List.exists contains_generic_type elems
  | Ast.TyFunc f ->
      List.exists contains_generic_type f.params
      || contains_generic_type f.return
  | Ast.TyRange inner -> contains_generic_type inner
  | Ast.TyDimOp (_, a, b) -> contains_generic_type a || contains_generic_type b
  | Ast.TyConstInt _ -> false

let normalize_for_result_layout ty =
  Types.map_type_expr
    (function
      | Ast.TyNamed (("Vector" | "Matrix"), args) ->
          Some (Ast.TyNamed ("Tensor", args))
      | Ast.TyNamed ("LiteralString", []) -> Some (Ast.TyNamed ("String", []))
      | _ -> None)
    ty

let rec expand_aliases (meta : metadata) seen ty =
  match normalize_for_result_layout ty with
  | Ast.TyNamed (name, args) -> (
      let args = List.map (expand_aliases meta seen) args in
      match meta.lookup_alias name with
      | Some (params, target) when not (List.mem name seen) ->
          if List.length params = List.length args then
            expand_aliases meta (name :: seen)
              (Types.apply_type_param_subst (List.combine params args) target)
          else Ast.TyNamed (name, args)
      | Some _ | None -> Ast.TyNamed (name, args))
  | Ast.TyArray (elem, dims) ->
      Ast.TyArray
        (expand_aliases meta seen elem, List.map (expand_aliases meta seen) dims)
  | Ast.TyTuple elems -> Ast.TyTuple (List.map (expand_aliases meta seen) elems)
  | Ast.TyFunc f ->
      Ast.TyFunc
        {
          f with
          params = List.map (expand_aliases meta seen) f.params;
          return = expand_aliases meta seen f.return;
        }
  | Ast.TyRange inner -> Ast.TyRange (expand_aliases meta seen inner)
  | Ast.TyDimOp (op, a, b) ->
      Types.Dim.normalize
        (Ast.TyDimOp (op, expand_aliases meta seen a, expand_aliases meta seen b))
  | ty -> ty

let is_immediate_integer_name = function
  | "Int128" | "UInt128" -> false
  | name -> List.mem name Types.all_int_type_names

let expanded_payload_is_stack_erased meta = function
  | Ast.TyNamed (("Int" | "Bool" | "Char" | "Ptr"), []) -> true
  | Ast.TyNamed (("Float" | "Float32" | "Float16"), []) -> true
  | Ast.TyNamed (name, []) when is_immediate_integer_name name -> true
  | Ast.TyNamed (name, []) when meta.is_enum_name name -> true
  | Ast.TyRange _ -> true
  | Ast.TyVar name when Types.Dim.is_var_name name -> true
  | Ast.TyConstInt _ | Ast.TyDimOp _ -> true
  | _ -> false

let payload_is_stack_erased meta payload_ty =
  expanded_payload_is_stack_erased meta (expand_aliases meta [] payload_ty)

let is_builtin_managed_payload_name = function
  | "String" | "List" | "ParallelList" | "ParallelVector" | "ParallelMatrix"
  | "Dict" | "Set" | "Tensor" | "Vector" | "Matrix" | "Bytes" | "Fixed"
  | "StringSlice" | "MemStats" | "SchedulerStats" | "Builder" | "Slice" | "Task"
  | "Channel" | "Stream" | "Option" | "Result" | "TcpListener" | "TcpStream"
  | "ConcurrencyError" ->
      true
  | _ -> false

type payload_status =
  | PayloadErased
  | PayloadManaged
  | PayloadGeneric
  | PayloadUnknownNamed of string
  | PayloadUnsupported of string

let payload_status_of_expanded meta ty =
  if contains_generic_type ty then PayloadGeneric
  else if expanded_payload_is_stack_erased meta ty then PayloadErased
  else
    match ty with
    | Ast.TyNamed (("Int128" | "UInt128"), []) -> PayloadManaged
    | Ast.TyNamed (("Void" | "Module"), []) ->
        PayloadUnsupported (string_of_type ty)
    | Ast.TyNamed (name, _) when is_builtin_managed_payload_name name ->
        PayloadManaged
    | Ast.TyNamed (name, _) when meta.is_managed_name name -> PayloadManaged
    | Ast.TyNamed (name, _) when meta.is_value_record_name name ->
        PayloadManaged
    | Ast.TyNamed (name, _) when meta.is_enum_name name -> PayloadErased
    | Ast.TyNamed (name, _) -> PayloadUnknownNamed name
    | Ast.TyArray _ | Ast.TyTuple _ | Ast.TyFunc _ -> PayloadManaged
    | Ast.TyVar _ | Ast.TyBoundVar _ | Ast.TySelf | Ast.TyVarDims _
    | Ast.TyMeta _ ->
        PayloadGeneric
    | Ast.TyRange _ | Ast.TyConstInt _ | Ast.TyDimOp _ -> PayloadErased

let payload_status meta payload_ty =
  payload_status_of_expanded meta (expand_aliases meta [] payload_ty)

let classification_from_payloads ok_status err_status =
  match (ok_status, err_status) with
  | PayloadErased, PayloadErased -> Known StackErased
  | (PayloadErased | PayloadManaged), (PayloadErased | PayloadManaged) ->
      Known StackManaged
  | PayloadUnknownNamed name, _ | _, PayloadUnknownNamed name ->
      Unknown_named name
  | PayloadGeneric, _ | _, PayloadGeneric -> BoxedUnion GenericPayload
  | PayloadUnsupported ty, _ | _, PayloadUnsupported ty ->
      BoxedUnion (UnsupportedPayload ty)

let classify (meta : metadata) (result_ty : Ast.type_expr) : classification =
  match expand_aliases meta [] result_ty with
  | Ast.TyNamed ("Result", [ ok_ty; err_ty ]) ->
      let ok_status = payload_status_of_expanded meta ok_ty in
      let err_status = payload_status_of_expanded meta err_ty in
      classification_from_payloads ok_status err_status
  | Ast.TyNamed ("Result", args) ->
      Invalid_result_type
        (Printf.sprintf "Result expects 2 arguments, got %d" (List.length args))
  | ty ->
      Invalid_result_type
        (Printf.sprintf "expected Result[T, E], got %s" (string_of_type ty))
